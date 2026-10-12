#include "sevenzip.hpp"
#include "runtime_paths.hpp"

#include <boost/filesystem.hpp>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <string_view>

#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// 7-Zip's interface declarations. MyInitGuid.h makes this file the one that defines the interface IDs.
#include <CPP/Common/MyInitGuid.h>
#include <CPP/7zip/Archive/IArchive.h>
#include <CPP/7zip/IPassword.h>
#include <C/7zVersion.h>

#ifndef FC_SEVENZIP_LIB_DEFAULT
#define FC_SEVENZIP_LIB_DEFAULT ""
#endif

static_assert(sizeof(wchar_t) == 4, "7-Zip's OLECHAR is UTF-32 wchar_t on this platform");

namespace SevenZip {
namespace {

// GetModuleProp's property IDs and the IUnknown layout FC's declarations assume (7-Zip's ICoder.h).
constexpr PROPID kModuleInterfaceType = 0, kModuleVersion = 1;
constexpr UInt32 kIUnknownWithoutVirtualDestructor = 0;
constexpr UInt32 kExpectedVersion = (UInt32(MY_VER_MAJOR) << 16) | UInt32(MY_VER_MINOR);
// 100 ns intervals between 1601-01-01 (FILETIME) and 1970-01-01.
constexpr int64_t kFiletimeUnixEpoch = 116444736000000000LL;

using CreateObjectFn = HRESULT (*)(const GUID*, const GUID*, void**);
using GetNumberOfFormatsFn = HRESULT (*)(UInt32*);
using GetHandlerProperty2Fn = HRESULT (*)(UInt32, PROPID, PROPVARIANT*);
using GetModulePropFn = HRESULT (*)(PROPID, PROPVARIANT*);
using SysAllocStringLenFn = BSTR (*)(const OLECHAR*, UINT);
using SysFreeStringFn = void (*)(BSTR);
using SysStringByteLenFn = UINT (*)(BSTR);
using VariantClearFn = HRESULT (*)(VARIANTARG*);

struct HandlerInfo {
  Format format;
  GUID class_id{};
  std::vector<std::vector<unsigned char>> signatures;
  uint32_t signature_offset = 0;
};

struct Library {
  void* handle = nullptr;
  std::string error;
  std::vector<Format> formats;
  std::vector<HandlerInfo> handlers;
  CreateObjectFn create_object = nullptr;
  SysAllocStringLenFn alloc_string = nullptr;
  SysFreeStringFn free_string = nullptr;
  SysStringByteLenFn byte_length = nullptr;
  VariantClearFn variant_clear = nullptr;
};

std::mutex g_path_mutex;
Filepath g_requested_path;

// A PROPVARIANT the library filled in, cleared by the library's own allocator.
struct Variant {
  PROPVARIANT value{};
  const Library& lib;
  explicit Variant(const Library& l) : lib(l) { value.vt = VT_EMPTY; }
  ~Variant() { lib.variant_clear(reinterpret_cast<VARIANTARG*>(&value)); }
  Variant(const Variant&) = delete;
  Variant& operator=(const Variant&) = delete;
};

std::string utf8(const wchar_t* text, size_t length) {
  std::string out;
  out.reserve(length);
  for (size_t i = 0; i < length; ++i) {
    auto c = static_cast<uint32_t>(text[i]);
    if (c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) c = 0xFFFD;
    if (c < 0x80) out.push_back(char(c));
    else if (c < 0x800) { out.push_back(char(0xC0 | (c >> 6))); out.push_back(char(0x80 | (c & 0x3F))); }
    else if (c < 0x10000) { out.push_back(char(0xE0 | (c >> 12))); out.push_back(char(0x80 | ((c >> 6) & 0x3F))); out.push_back(char(0x80 | (c & 0x3F))); }
    else { out.push_back(char(0xF0 | (c >> 18))); out.push_back(char(0x80 | ((c >> 12) & 0x3F))); out.push_back(char(0x80 | ((c >> 6) & 0x3F))); out.push_back(char(0x80 | (c & 0x3F))); }
  }
  return out;
}

std::wstring wide(std::string_view text) {
  std::wstring out;
  out.reserve(text.size());
  for (size_t i = 0; i < text.size();) {
    const auto b = static_cast<unsigned char>(text[i]);
    uint32_t c = 0xFFFD;
    size_t n = 1;
    if (b < 0x80) c = b;
    else if ((b >> 5) == 0x6 && i + 1 < text.size()) { c = ((b & 0x1F) << 6) | (text[i + 1] & 0x3F); n = 2; }
    else if ((b >> 4) == 0xE && i + 2 < text.size()) { c = ((b & 0x0F) << 12) | ((text[i + 1] & 0x3F) << 6) | (text[i + 2] & 0x3F); n = 3; }
    else if ((b >> 3) == 0x1E && i + 3 < text.size()) { c = ((b & 0x07) << 18) | ((text[i + 1] & 0x3F) << 12) | ((text[i + 2] & 0x3F) << 6) | (text[i + 3] & 0x3F); n = 4; }
    out.push_back(static_cast<wchar_t>(c));
    i += n;
  }
  return out;
}

std::string string_of(const Library& lib, const PROPVARIANT& v) {
  if (v.vt != VT_BSTR || !v.bstrVal) return {};
  return utf8(v.bstrVal, lib.byte_length(v.bstrVal) / sizeof(OLECHAR));
}

std::optional<uint64_t> number_of(const PROPVARIANT& v) {
  switch (v.vt) {
    case VT_UI1: return v.bVal;
    case VT_UI2: return v.uiVal;
    case VT_UI4: return v.ulVal;
    case VT_UI8: return v.uhVal.QuadPart;
    case VT_I4: if (v.lVal >= 0) return uint64_t(v.lVal); break;
    case VT_I8: if (v.hVal.QuadPart >= 0) return uint64_t(v.hVal.QuadPart); break;
    default: break;
  }
  return std::nullopt;
}

bool bool_of(const PROPVARIANT& v) { return v.vt == VT_BOOL && v.boolVal != VARIANT_FALSE; }

int64_t unix_ns(const FILETIME& t) {
  const int64_t ticks = int64_t((uint64_t(t.dwHighDateTime) << 32) | t.dwLowDateTime);
  return (ticks - kFiletimeUnixEpoch) * 100;
}

FILETIME filetime_of(int64_t seconds, int64_t nanoseconds) {
  const uint64_t ticks = uint64_t(seconds * 10000000LL + nanoseconds / 100 + kFiletimeUnixEpoch);
  FILETIME t;
  t.dwLowDateTime = DWORD(ticks & 0xFFFFFFFFu);
  t.dwHighDateTime = DWORD(ticks >> 32);
  return t;
}

std::string hresult_text(HRESULT hr) {
  switch (hr) {
    case E_ABORT: return "cancelled";
    case E_OUTOFMEMORY: return "out of memory";
    case E_NOTIMPL: return "not supported for this format";
    case S_FALSE: return "not an archive of this format";
    default: break;
  }
  char text[32];
  std::snprintf(text, sizeof text, "error 0x%08X", unsigned(hr));
  return text;
}

std::string operation_result_text(Int32 result) {
  using namespace NArchive::NExtract::NOperationResult;
  switch (result) {
    case kOK: return {};
    case kUnsupportedMethod: return "uses a compression method FC can't decode";
    case kDataError: return "data error";
    case kCRCError: return "checksum mismatch";
    case kUnavailable: return "data unavailable";
    case kUnexpectedEnd: return "archive ends early";
    case kDataAfterEnd: return "data after the end of the entry";
    case kIsNotArc: return "not an archive";
    case kHeadersError: return "damaged headers";
    case kWrongPassword: return "wrong password";
    default: return "extraction error " + std::to_string(result);
  }
}

template <class T>
T symbol(void* handle, const char* name) {
  return reinterpret_cast<T>(dlsym(handle, name));
}

Library load() {
  Library lib;
  std::vector<Filepath> candidates;
  {
    std::lock_guard lock(g_path_mutex);
    if (!g_requested_path.empty()) candidates.push_back(g_requested_path);
  }
  if (candidates.empty()) {
    const auto dir = executable_dir_path();
    if (!dir.empty()) {
      candidates.push_back(dir / "7z.so");
      candidates.push_back(dir.parent_path() / "lib" / "file-commander" / "7z.so");
    }
    if (*FC_SEVENZIP_LIB_DEFAULT) candidates.push_back(Filepath(FC_SEVENZIP_LIB_DEFAULT));
  }
  Filepath chosen;
  for (const auto& path : candidates) {
    boost::system::error_code ec;
    if (boost::filesystem::is_regular_file(path, ec)) { chosen = path; break; }
  }
  if (chosen.empty()) {
    lib.error = "7z.so not found";
    return lib;
  }
  lib.handle = dlopen(chosen.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!lib.handle) {
    const char* why = dlerror();
    lib.error = "cannot load " + chosen.native() + ": " + (why ? why : "unknown error");
    return lib;
  }
  lib.create_object = symbol<CreateObjectFn>(lib.handle, "CreateObject");
  auto number_of_formats = symbol<GetNumberOfFormatsFn>(lib.handle, "GetNumberOfFormats");
  auto handler_property = symbol<GetHandlerProperty2Fn>(lib.handle, "GetHandlerProperty2");
  auto module_property = symbol<GetModulePropFn>(lib.handle, "GetModuleProp");
  lib.alloc_string = symbol<SysAllocStringLenFn>(lib.handle, "SysAllocStringLen");
  lib.free_string = symbol<SysFreeStringFn>(lib.handle, "SysFreeString");
  lib.byte_length = symbol<SysStringByteLenFn>(lib.handle, "SysStringByteLen");
  lib.variant_clear = symbol<VariantClearFn>(lib.handle, "VariantClear");
  if (!lib.create_object || !number_of_formats || !handler_property || !module_property || !lib.alloc_string || !lib.free_string ||
      !lib.byte_length || !lib.variant_clear) {
    lib.error = chosen.native() + " is not 7-Zip's archive library";
    return lib;
  }
  {
    Variant type(lib), version(lib);
    if (module_property(kModuleInterfaceType, &type.value) != S_OK || module_property(kModuleVersion, &version.value) != S_OK ||
        number_of(type.value) != kIUnknownWithoutVirtualDestructor || number_of(version.value) != kExpectedVersion) {
      lib.error = chosen.native() + " is not 7-Zip " MY_VERSION_NUMBERS ", which FC was built against";
      return lib;
    }
  }
  UInt32 count = 0;
  if (number_of_formats(&count) != S_OK) {
    lib.error = "cannot list the formats in " + chosen.native();
    return lib;
  }
  for (UInt32 i = 0; i < count; ++i) {
    HandlerInfo info;
    Variant name(lib), id(lib), extensions(lib), update(lib), signature(lib), multi(lib), offset(lib);
    handler_property(i, NArchive::NHandlerPropID::kName, &name.value);
    handler_property(i, NArchive::NHandlerPropID::kClassID, &id.value);
    handler_property(i, NArchive::NHandlerPropID::kExtension, &extensions.value);
    handler_property(i, NArchive::NHandlerPropID::kUpdate, &update.value);
    handler_property(i, NArchive::NHandlerPropID::kSignature, &signature.value);
    handler_property(i, NArchive::NHandlerPropID::kMultiSignature, &multi.value);
    handler_property(i, NArchive::NHandlerPropID::kSignatureOffset, &offset.value);
    if (id.value.vt != VT_BSTR || !id.value.bstrVal || lib.byte_length(id.value.bstrVal) < sizeof(GUID)) continue;
    std::memcpy(&info.class_id, id.value.bstrVal, sizeof(GUID));
    info.format.name = string_of(lib, name.value);
    std::string list = string_of(lib, extensions.value);
    for (size_t start = 0; start < list.size();) {
      auto end = list.find(' ', start);
      if (end == std::string::npos) end = list.size();
      if (end > start) {
        std::string ext = list.substr(start, end - start);
        std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return char(std::tolower(c)); });
        info.format.extensions.push_back(ext);
      }
      start = end + 1;
    }
    info.format.writable = bool_of(update.value);
    if (signature.value.vt == VT_BSTR && signature.value.bstrVal) {
      const auto* bytes = reinterpret_cast<const unsigned char*>(signature.value.bstrVal);
      info.signatures.emplace_back(bytes, bytes + lib.byte_length(signature.value.bstrVal));
    }
    if (multi.value.vt == VT_BSTR && multi.value.bstrVal) {
      // Length-prefixed signatures, one after another.
      const auto* bytes = reinterpret_cast<const unsigned char*>(multi.value.bstrVal);
      const size_t total = lib.byte_length(multi.value.bstrVal);
      for (size_t at = 0; at < total;) {
        const size_t length = bytes[at++];
        if (length == 0 || at + length > total) break;
        info.signatures.emplace_back(bytes + at, bytes + at + length);
        at += length;
      }
    }
    info.signature_offset = uint32_t(number_of(offset.value).value_or(0));
    if (info.format.name.empty()) continue;
    lib.formats.push_back(info.format);
    lib.handlers.push_back(std::move(info));
  }
  return lib;
}

const Library& library() {
  static const Library lib = load();
  return lib;
}

// COM reference counting shared by FC's objects. Each class answers QueryInterface for its own interfaces.
class RefCounted {
 public:
  virtual ~RefCounted() = default;

 protected:
  ULONG add_ref() { return ++_refs; }
  ULONG release() {
    const ULONG left = --_refs;
    if (left == 0) delete this;
    return left;
  }

 private:
  std::atomic<ULONG> _refs{0};
};

// Holds one reference to a COM object.
template <class T>
class ComPtr {
 public:
  ComPtr() = default;
  explicit ComPtr(T* p) : _p(p) { if (_p) _p->AddRef(); }
  ComPtr(const ComPtr& o) : ComPtr(o._p) {}
  ComPtr& operator=(const ComPtr& o) { ComPtr(o).swap(*this); return *this; }
  ~ComPtr() { if (_p) _p->Release(); }
  void swap(ComPtr& o) { std::swap(_p, o._p); }
  // Takes a reference the callee already added (an out parameter).
  T** put() { if (_p) _p->Release(); _p = nullptr; return &_p; }
  T* get() const { return _p; }
  T* operator->() const { return _p; }
  explicit operator bool() const { return _p != nullptr; }

 private:
  T* _p = nullptr;
};

HRESULT seek_fd(int fd, Int64 offset, UInt32 origin, UInt64* position) {
  int whence = SEEK_SET;
  if (origin == STREAM_SEEK_CUR) whence = SEEK_CUR;
  else if (origin == STREAM_SEEK_END) whence = SEEK_END;
  else if (origin != STREAM_SEEK_SET) return STG_E_INVALIDFUNCTION;
  const off_t at = ::lseek(fd, off_t(offset), whence);
  if (at < 0) return HRESULT_FROM_WIN32(errno);
  if (position) *position = UInt64(at);
  return S_OK;
}

class InFile final : public IInStream, public IStreamGetSize, public RefCounted {
 public:
  static ComPtr<InFile> open(const Filepath& path, int& error) {
    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) { error = errno; return {}; }
    return ComPtr<InFile>(new InFile(fd));
  }
  STDMETHOD(QueryInterface)(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_ISequentialInStream || iid == IID_IInStream) *out = static_cast<IInStream*>(this);
    else if (iid == IID_IStreamGetSize) *out = static_cast<IStreamGetSize*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  STDMETHOD_(ULONG, AddRef)() override { return add_ref(); }
  STDMETHOD_(ULONG, Release)() override { return release(); }
  STDMETHODIMP Read(void* data, UInt32 size, UInt32* processed) noexcept override {
    if (processed) *processed = 0;
    for (;;) {
      const ssize_t n = ::read(_fd, data, size);
      if (n >= 0) {
        if (processed) *processed = UInt32(n);
        _consumed += uint64_t(n);
        return S_OK;
      }
      if (errno != EINTR) return HRESULT_FROM_WIN32(errno);
    }
  }
  // Bytes read so far, for progress through a file read once.
  uint64_t consumed() const { return _consumed.load(); }
  uint64_t size() const {
    struct stat info{};
    return ::fstat(_fd, &info) == 0 ? uint64_t(info.st_size) : 0;
  }
  STDMETHODIMP Seek(Int64 offset, UInt32 origin, UInt64* position) noexcept override { return seek_fd(_fd, offset, origin, position); }
  STDMETHODIMP GetSize(UInt64* size) noexcept override {
    struct stat info{};
    if (::fstat(_fd, &info) != 0) return HRESULT_FROM_WIN32(errno);
    *size = UInt64(info.st_size);
    return S_OK;
  }

 private:
  explicit InFile(int fd) : _fd(fd) {}
  ~InFile() override { ::close(_fd); }
  int _fd;
  std::atomic<uint64_t> _consumed{0};
};

class OutFile final : public IOutStream, public RefCounted {
 public:
  // A new file, created exclusively, owner-only until the caller decides its permissions.
  static ComPtr<OutFile> create(const Filepath& path, int& error) {
    const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) { error = errno; return {}; }
    return ComPtr<OutFile>(new OutFile(fd));
  }
  STDMETHOD(QueryInterface)(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_ISequentialOutStream || iid == IID_IOutStream) *out = static_cast<IOutStream*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  STDMETHOD_(ULONG, AddRef)() override { return add_ref(); }
  STDMETHOD_(ULONG, Release)() override { return release(); }
  STDMETHODIMP Write(const void* data, UInt32 size, UInt32* processed) noexcept override {
    if (processed) *processed = 0;
    const auto* bytes = static_cast<const char*>(data);
    UInt32 done = 0;
    while (done < size) {
      const ssize_t n = ::write(_fd, bytes + done, size - done);
      if (n < 0) {
        if (errno == EINTR) continue;
        if (processed) *processed = done;
        return HRESULT_FROM_WIN32(errno);
      }
      done += UInt32(n);
    }
    if (processed) *processed = done;
    return S_OK;
  }
  STDMETHODIMP Seek(Int64 offset, UInt32 origin, UInt64* position) noexcept override { return seek_fd(_fd, offset, origin, position); }
  STDMETHODIMP SetSize(UInt64 size) noexcept override { return ::ftruncate(_fd, off_t(size)) == 0 ? S_OK : HRESULT_FROM_WIN32(errno); }
  // Closes the file, reporting what close itself reports.
  int close() {
    if (_fd < 0) return 0;
    const int result = ::close(_fd);
    _fd = -1;
    return result == 0 ? 0 : errno;
  }

 private:
  explicit OutFile(int fd) : _fd(fd) {}
  ~OutFile() override { if (_fd >= 0) ::close(_fd); }
  int _fd;
};

// Asks the caller's PasswordSource and hands the library a string it can free.
struct PasswordAsker {
  const PasswordSource& source;
  bool refused = false;
  HRESULT ask(BSTR* out) {
    *out = nullptr;
    auto password = source ? source() : std::nullopt;
    if (!password) {
      refused = true;
      return E_ABORT;
    }
    const auto text = wide(*password);
    *out = library().alloc_string(text.data(), UINT(text.size()));
    return *out ? S_OK : E_OUTOFMEMORY;
  }
};

HRESULT report_progress(const Progress& progress, UInt64 done, UInt64 total) {
  if (progress.cancelled && progress.cancelled->load()) return E_ABORT;
  if (progress.report) progress.report(done, total);
  return S_OK;
}

class OpenCallback final : public IArchiveOpenCallback, public ICryptoGetTextPassword, public RefCounted {
 public:
  OpenCallback(const PasswordSource& password, const Progress& progress) : _password{password}, _progress(progress) {}
  STDMETHOD(QueryInterface)(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_IArchiveOpenCallback) *out = static_cast<IArchiveOpenCallback*>(this);
    else if (iid == IID_ICryptoGetTextPassword) *out = static_cast<ICryptoGetTextPassword*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  STDMETHOD_(ULONG, AddRef)() override { return add_ref(); }
  STDMETHOD_(ULONG, Release)() override { return release(); }
  STDMETHODIMP SetTotal(const UInt64*, const UInt64* bytes) noexcept override {
    if (bytes) _total = *bytes;
    return report_progress(_progress, 0, _total);
  }
  STDMETHODIMP SetCompleted(const UInt64*, const UInt64* bytes) noexcept override { return report_progress(_progress, bytes ? *bytes : 0, _total); }
  STDMETHODIMP CryptoGetTextPassword(BSTR* password) noexcept override { return _password.ask(password); }
  bool password_refused() const { return _password.refused; }

 private:
  PasswordAsker _password;
  const Progress& _progress;
  UInt64 _total = 0;
};

}  // namespace

struct Archive::State {
  std::mutex mutex;
  ComPtr<IInArchive> handler;
  ComPtr<InFile> stream;
  std::string format;
  std::vector<Entry> entries;
  ~State() {
    if (handler) handler->Close();
  }
};

namespace {

class ExtractCallback final : public IArchiveExtractCallback, public ICryptoGetTextPassword, public RefCounted {
 public:
  ExtractCallback(const std::vector<Entry>& entries, const std::function<Filepath(const Entry&)>& output,
                  const std::function<void(const Entry&, Err)>& finished, const PasswordSource& password, const Progress& progress)
      : _entries(entries), _output(output), _finished(finished), _password{password}, _progress(progress) {}
  STDMETHOD(QueryInterface)(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_IProgress || iid == IID_IArchiveExtractCallback) *out = static_cast<IArchiveExtractCallback*>(this);
    else if (iid == IID_ICryptoGetTextPassword) *out = static_cast<ICryptoGetTextPassword*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  STDMETHOD_(ULONG, AddRef)() override { return add_ref(); }
  STDMETHOD_(ULONG, Release)() override { return release(); }
  STDMETHODIMP SetTotal(UInt64 total) noexcept override {
    _total = total;
    return report_progress(_progress, 0, _total);
  }
  STDMETHODIMP SetCompleted(const UInt64* done) noexcept override { return report_progress(_progress, done ? *done : 0, _total); }
  STDMETHODIMP GetStream(UInt32 index, ISequentialOutStream** out, Int32 mode) noexcept override {
    *out = nullptr;
    finish_current(NArchive::NExtract::NOperationResult::kOK);
    if (mode != NArchive::NExtract::NAskMode::kExtract || index >= _entries.size()) return S_OK;
    const Entry& entry = _entries[index];
    if (entry.directory || !entry.symlink.empty()) return S_OK;
    Filepath path;
    try {
      path = _output(entry);
    } catch (...) {
      return E_FAIL;
    }
    if (path.empty()) return S_OK;
    int error = 0;
    auto file = OutFile::create(path, error);
    _current = &entry;
    if (!file) {
      _open_error = "cannot create " + path.native() + ": " + std::strerror(error);
      return S_OK;
    }
    _file = file;
    *out = file.get();
    file->AddRef();
    return S_OK;
  }
  STDMETHODIMP PrepareOperation(Int32) noexcept override { return S_OK; }
  STDMETHODIMP SetOperationResult(Int32 result) noexcept override {
    finish_current(result);
    return S_OK;
  }
  STDMETHODIMP CryptoGetTextPassword(BSTR* password) noexcept override { return _password.ask(password); }
  bool password_refused() const { return _password.refused; }
  // Reports the entry still open when the library stops early.
  void abandon(const std::string& why) {
    if (_current) {
      _open_error = why;
      finish_current(NArchive::NExtract::NOperationResult::kOK);
    }
  }

 private:
  void finish_current(Int32 result) {
    if (!_current) return;
    const Entry& entry = *_current;
    std::string why = _open_error;
    if (_file) {
      if (const int error = _file->close(); error != 0 && why.empty()) why = std::string("cannot write: ") + std::strerror(error);
      _file = {};
    }
    if (why.empty()) why = operation_result_text(result);
    _current = nullptr;
    _open_error.clear();
    if (_finished) {
      try {
        _finished(entry, why.empty() ? Err() : Err(entry.path + ": " + why));
      } catch (...) {
      }
    }
  }

  const std::vector<Entry>& _entries;
  const std::function<Filepath(const Entry&)>& _output;
  const std::function<void(const Entry&, Err)>& _finished;
  PasswordAsker _password;
  const Progress& _progress;
  UInt64 _total = 0;
  const Entry* _current = nullptr;
  ComPtr<OutFile> _file;
  std::string _open_error;
};

struct Source {
  Filepath path;
  std::string name;
  bool directory = false;
  uint64_t size = 0;
  struct stat info{};
};

class UpdateCallback final : public IArchiveUpdateCallback, public ICryptoGetTextPassword2, public RefCounted {
 public:
  UpdateCallback(const std::vector<Source>& items, const Progress& progress) : _items(items), _progress(progress) {}
  STDMETHOD(QueryInterface)(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_IProgress || iid == IID_IArchiveUpdateCallback) *out = static_cast<IArchiveUpdateCallback*>(this);
    else if (iid == IID_ICryptoGetTextPassword2) *out = static_cast<ICryptoGetTextPassword2*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  STDMETHOD_(ULONG, AddRef)() override { return add_ref(); }
  STDMETHOD_(ULONG, Release)() override { return release(); }
  STDMETHODIMP SetTotal(UInt64 total) noexcept override {
    _total = total;
    return report_progress(_progress, 0, _total);
  }
  STDMETHODIMP SetCompleted(const UInt64* done) noexcept override { return report_progress(_progress, done ? *done : 0, _total); }
  STDMETHODIMP GetUpdateItemInfo(UInt32, Int32* new_data, Int32* new_properties, UInt32* index_in_archive) noexcept override {
    if (new_data) *new_data = 1;
    if (new_properties) *new_properties = 1;
    if (index_in_archive) *index_in_archive = UInt32(-1);
    return S_OK;
  }
  STDMETHODIMP GetProperty(UInt32 index, PROPID id, PROPVARIANT* value) noexcept override {
    if (index >= _items.size()) return E_INVALIDARG;
    const Source& item = _items[index];
    const auto& lib = library();
    lib.variant_clear(reinterpret_cast<VARIANTARG*>(value));
    switch (id) {
      case kpidPath: {
        const auto name = wide(item.name);
        value->bstrVal = lib.alloc_string(name.data(), UINT(name.size()));
        if (!value->bstrVal) return E_OUTOFMEMORY;
        value->vt = VT_BSTR;
        break;
      }
      case kpidIsDir: value->vt = VT_BOOL; value->boolVal = item.directory ? VARIANT_TRUE : VARIANT_FALSE; break;
      case kpidIsAnti: value->vt = VT_BOOL; value->boolVal = VARIANT_FALSE; break;
      case kpidSize: value->vt = VT_UI8; value->uhVal.QuadPart = item.size; break;
      case kpidAttrib:
        value->vt = VT_UI4;
        value->ulVal = (item.directory ? FILE_ATTRIBUTE_DIRECTORY : 0) | FILE_ATTRIBUTE_UNIX_EXTENSION | (UInt32(item.info.st_mode & 0xFFFF) << 16);
        break;
      case kpidPosixAttrib: value->vt = VT_UI4; value->ulVal = UInt32(item.info.st_mode); break;
      case kpidMTime:
        value->vt = VT_FILETIME;
#if defined(__APPLE__)
        value->filetime = filetime_of(item.info.st_mtimespec.tv_sec, item.info.st_mtimespec.tv_nsec);
#else
        value->filetime = filetime_of(item.info.st_mtim.tv_sec, item.info.st_mtim.tv_nsec);
#endif
        break;
      default: break;
    }
    return S_OK;
  }
  STDMETHODIMP GetStream(UInt32 index, ISequentialInStream** out) noexcept override {
    *out = nullptr;
    if (index >= _items.size()) return E_INVALIDARG;
    if (_items[index].directory) return S_OK;
    int error = 0;
    auto file = InFile::open(_items[index].path, error);
    if (!file) {
      _error = "cannot read " + _items[index].path.native() + ": " + std::strerror(error);
      return E_FAIL;
    }
    *out = static_cast<IInStream*>(file.get());
    file->AddRef();
    return S_OK;
  }
  STDMETHODIMP SetOperationResult(Int32) noexcept override { return S_OK; }
  STDMETHODIMP CryptoGetTextPassword2(Int32* defined, BSTR* password) noexcept override {
    *defined = 0;
    *password = nullptr;
    return S_OK;
  }
  const std::string& error() const { return _error; }

 private:
  const std::vector<Source>& _items;
  const Progress& _progress;
  UInt64 _total = 0;
  std::string _error;
};

Entry entry_at(const Library& lib, IInArchive* handler, UInt32 i, const Filepath& file);

// A bounded byte queue from one writer thread to one reader: a compressed stream's handler decodes into it while tar reads from it, so the decompressed tar is never stored.
class Pipe {
 public:
  explicit Pipe(size_t capacity) : _buffer(capacity) {}
  HRESULT write(const char* data, size_t size) {
    std::unique_lock lock(_mutex);
    while (size > 0) {
      _changed.wait(lock, [&] { return _count < _buffer.size() || _reader_gone; });
      if (_reader_gone) return E_ABORT;
      const size_t n = std::min(size, _buffer.size() - _count);
      for (size_t i = 0; i < n; ++i) _buffer[(_start + _count + i) % _buffer.size()] = data[i];
      _count += n;
      data += n;
      size -= n;
      _changed.notify_all();
    }
    return S_OK;
  }
  // Fewer bytes than asked, or none at the end of the stream.
  size_t read(char* data, size_t size) {
    std::unique_lock lock(_mutex);
    _changed.wait(lock, [&] { return _count > 0 || _writer_done; });
    const size_t n = std::min(size, _count);
    for (size_t i = 0; i < n; ++i) data[i] = _buffer[(_start + i) % _buffer.size()];
    _start = (_start + n) % _buffer.size();
    _count -= n;
    _changed.notify_all();
    return n;
  }
  void close_writer() {
    std::lock_guard lock(_mutex);
    _writer_done = true;
    _changed.notify_all();
  }
  void close_reader() {
    std::lock_guard lock(_mutex);
    _reader_gone = true;
    _changed.notify_all();
  }

 private:
  std::mutex _mutex;
  std::condition_variable _changed;
  std::vector<char> _buffer;
  size_t _start = 0, _count = 0;
  bool _writer_done = false, _reader_gone = false;
};

class PipeWriter final : public ISequentialOutStream, public RefCounted {
 public:
  explicit PipeWriter(std::shared_ptr<Pipe> pipe) : _pipe(std::move(pipe)) {}
  STDMETHOD(QueryInterface)(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_ISequentialOutStream) *out = static_cast<ISequentialOutStream*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  STDMETHOD_(ULONG, AddRef)() override { return add_ref(); }
  STDMETHOD_(ULONG, Release)() override { return release(); }
  STDMETHODIMP Write(const void* data, UInt32 size, UInt32* processed) noexcept override {
    const HRESULT hr = _pipe->write(static_cast<const char*>(data), size);
    if (processed) *processed = hr == S_OK ? size : 0;
    return hr;
  }

 private:
  std::shared_ptr<Pipe> _pipe;
};

class PipeReader final : public ISequentialInStream, public RefCounted {
 public:
  explicit PipeReader(std::shared_ptr<Pipe> pipe) : _pipe(std::move(pipe)) {}
  STDMETHOD(QueryInterface)(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_ISequentialInStream) *out = static_cast<ISequentialInStream*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  STDMETHOD_(ULONG, AddRef)() override { return add_ref(); }
  STDMETHOD_(ULONG, Release)() override { return release(); }
  STDMETHODIMP Read(void* data, UInt32 size, UInt32* processed) noexcept override {
    const size_t n = _pipe->read(static_cast<char*>(data), size);
    if (processed) *processed = UInt32(n);
    return S_OK;
  }

 private:
  std::shared_ptr<Pipe> _pipe;
};

// Decodes a compressed stream's single item into the pipe.
class PipeExtractCallback final : public IArchiveExtractCallback, public RefCounted {
 public:
  explicit PipeExtractCallback(std::shared_ptr<Pipe> pipe) : _pipe(std::move(pipe)) {}
  STDMETHOD(QueryInterface)(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_IProgress || iid == IID_IArchiveExtractCallback) *out = static_cast<IArchiveExtractCallback*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  STDMETHOD_(ULONG, AddRef)() override { return add_ref(); }
  STDMETHOD_(ULONG, Release)() override { return release(); }
  STDMETHODIMP SetTotal(UInt64) noexcept override { return S_OK; }
  STDMETHODIMP SetCompleted(const UInt64*) noexcept override { return S_OK; }
  STDMETHODIMP GetStream(UInt32, ISequentialOutStream** out, Int32 mode) noexcept override {
    *out = nullptr;
    if (mode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
    *out = new PipeWriter(_pipe);
    (*out)->AddRef();
    return S_OK;
  }
  STDMETHODIMP PrepareOperation(Int32) noexcept override { return S_OK; }
  STDMETHODIMP SetOperationResult(Int32 result) noexcept override {
    this->result = result;
    return S_OK;
  }
  Int32 result = NArchive::NExtract::NOperationResult::kOK;

 private:
  std::shared_ptr<Pipe> _pipe;
};

// Extracts entries of a tar read in order: each entry's properties are known only when tar reaches it.
class SequentialTarCallback final : public IArchiveExtractCallback, public RefCounted {
 public:
  SequentialTarCallback(IInArchive* tar, const Filepath& file, const std::function<Filepath(const Entry&)>& output,
                        const std::function<void(const Entry&, Err)>& finished, const Progress& progress, InFile* source)
      : _tar(tar), _file(file), _output(output), _finished(finished), _progress(progress), _source(source), _total(source->size()) {}
  STDMETHOD(QueryInterface)(REFIID iid, void** out) override {
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_IProgress || iid == IID_IArchiveExtractCallback) *out = static_cast<IArchiveExtractCallback*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  STDMETHOD_(ULONG, AddRef)() override { return add_ref(); }
  STDMETHOD_(ULONG, Release)() override { return release(); }
  STDMETHODIMP SetTotal(UInt64) noexcept override { return S_OK; }
  // Progress is the compressed bytes read, against the compressed file's size: the tar's own size isn't known until its end.
  STDMETHODIMP SetCompleted(const UInt64*) noexcept override { return report_progress(_progress, _source->consumed(), _total); }
  STDMETHODIMP GetStream(UInt32 index, ISequentialOutStream** out, Int32 mode) noexcept override {
    *out = nullptr;
    finish(NArchive::NExtract::NOperationResult::kOK);
    if (mode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
    try {
      _entry = entry_at(library(), _tar, index, _file);
    } catch (...) {
      return E_OUTOFMEMORY;
    }
    if (const HRESULT hr = report_progress(_progress, _source->consumed(), _total); hr != S_OK) return hr;
    Filepath path;
    try {
      path = _output(_entry);
    } catch (...) {
      return E_FAIL;
    }
    if (path.empty() || _entry.directory || !_entry.symlink.empty()) return S_OK;
    _current = true;
    int error = 0;
    auto file = OutFile::create(path, error);
    if (!file) {
      _open_error = "cannot create " + path.native() + ": " + std::strerror(error);
      return S_OK;
    }
    _out = file;
    *out = file.get();
    file->AddRef();
    return S_OK;
  }
  STDMETHODIMP PrepareOperation(Int32) noexcept override { return S_OK; }
  STDMETHODIMP SetOperationResult(Int32 result) noexcept override {
    finish(result);
    return S_OK;
  }
  void abandon(const std::string& why) {
    if (_current) {
      _open_error = why;
      finish(NArchive::NExtract::NOperationResult::kOK);
    }
  }

 private:
  void finish(Int32 result) {
    if (!_current) return;
    std::string why = _open_error;
    if (_out) {
      if (const int error = _out->close(); error != 0 && why.empty()) why = std::string("cannot write: ") + std::strerror(error);
      _out = {};
    }
    if (why.empty()) why = operation_result_text(result);
    _current = false;
    _open_error.clear();
    if (_finished) {
      try {
        _finished(_entry, why.empty() ? Err() : Err(_entry.path + ": " + why));
      } catch (...) {
      }
    }
  }

  IInArchive* _tar;
  const Filepath& _file;
  const std::function<Filepath(const Entry&)>& _output;
  const std::function<void(const Entry&, Err)>& _finished;
  const Progress& _progress;
  InFile* _source;
  uint64_t _total;
  Entry _entry;
  bool _current = false;
  ComPtr<OutFile> _out;
  std::string _open_error;
};

std::string lower_extension(const Filepath& file) {
  std::string ext = file.extension().native();
  if (!ext.empty() && ext.front() == '.') ext.erase(0, 1);
  std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return char(std::tolower(c)); });
  return ext;
}

// The handlers worth trying for `file`, best first: the one asked for, those claiming its extension, then those whose signature its first bytes carry.
std::vector<const HandlerInfo*> candidates(const Filepath& file, const std::string& format) {
  const auto& lib = library();
  std::vector<const HandlerInfo*> out;
  auto add = [&](const HandlerInfo& h) {
    if (std::find(out.begin(), out.end(), &h) == out.end()) out.push_back(&h);
  };
  for (const auto& h : lib.handlers)
    if (!format.empty() && h.format.name == format) add(h);
  const auto ext = lower_extension(file);
  for (const auto& h : lib.handlers)
    if (!ext.empty() && std::find(h.format.extensions.begin(), h.format.extensions.end(), ext) != h.format.extensions.end()) add(h);
  std::vector<unsigned char> head(64 * 1024);
  const int fd = ::open(file.c_str(), O_RDONLY | O_CLOEXEC);
  ssize_t got = 0;
  if (fd >= 0) {
    got = ::pread(fd, head.data(), head.size(), 0);
    ::close(fd);
  }
  head.resize(got > 0 ? size_t(got) : 0);
  for (const auto& h : lib.handlers)
    for (const auto& sig : h.signatures)
      if (!sig.empty() && h.signature_offset + sig.size() <= head.size() &&
          std::equal(sig.begin(), sig.end(), head.begin() + h.signature_offset))
        add(h);
  return out;
}

Entry entry_at(const Library& lib, IInArchive* handler, UInt32 i, const Filepath& file) {
    Entry e;
    e.index = i;
    Variant path(lib), dir(lib), size(lib), mtime(lib), attrib(lib), posix(lib), encrypted(lib), link(lib);
    handler->GetProperty(i, kpidPath, &path.value);
    handler->GetProperty(i, kpidIsDir, &dir.value);
    handler->GetProperty(i, kpidSize, &size.value);
    handler->GetProperty(i, kpidMTime, &mtime.value);
    handler->GetProperty(i, kpidAttrib, &attrib.value);
    handler->GetProperty(i, kpidPosixAttrib, &posix.value);
    handler->GetProperty(i, kpidEncrypted, &encrypted.value);
    handler->GetProperty(i, kpidSymLink, &link.value);
    e.path = string_of(lib, path.value);
    if (e.path.empty()) {
      // Single-stream formats (gzip, xz, ...) often keep no name: the archive's own name without its extension stands in, as in 7-Zip.
      e.path = file.stem().native();
      const auto ext = lower_extension(file);
      if (ext == "tgz" || ext == "tbz" || ext == "tbz2" || ext == "txz" || ext == "tzst" || ext == "tlz" || ext == "taz") e.path += ".tar";
    }
    e.directory = bool_of(dir.value);
    e.encrypted = bool_of(encrypted.value);
    e.size = number_of(size.value);
    if (mtime.value.vt == VT_FILETIME) e.modified_ns = unix_ns(mtime.value.filetime);
    if (auto mode = number_of(posix.value)) e.posix_mode = uint32_t(*mode);
    else if (auto a = number_of(attrib.value); a && (*a & FILE_ATTRIBUTE_UNIX_EXTENSION)) e.posix_mode = uint32_t(*a >> 16);
    if (!e.directory && e.posix_mode && S_ISDIR(*e.posix_mode)) e.directory = true;
    e.symlink = string_of(lib, link.value);
    return e;
}

void read_entries(const Library& lib, IInArchive* handler, const Filepath& file, std::vector<Entry>& entries) {
  UInt32 count = 0;
  if (handler->GetNumberOfItems(&count) != S_OK) return;
  entries.reserve(count);
  for (UInt32 i = 0; i < count; ++i) entries.push_back(entry_at(lib, handler, i, file));
}

void collect(const Filepath& path, const std::string& name, std::vector<Source>& out, Err& error) {
  Source s;
  s.path = path;
  s.name = name;
  if (::stat(path.c_str(), &s.info) != 0) {
    error = Err("cannot read " + path.native() + ": " + std::strerror(errno));
    return;
  }
  s.directory = S_ISDIR(s.info.st_mode);
  s.size = s.directory ? 0 : uint64_t(s.info.st_size);
  out.push_back(s);
  if (!s.directory) return;
  // A symlink to a folder is stored as an empty folder, so a link cycle can't recurse forever.
  struct stat own{};
  if (::lstat(path.c_str(), &own) == 0 && S_ISLNK(own.st_mode)) return;
  boost::system::error_code ec;
  std::vector<Filepath> children;
  for (boost::filesystem::directory_iterator it(path, ec), end; !ec && it != end; it.increment(ec)) children.push_back(it->path());
  if (ec) {
    error = Err("cannot list " + path.native() + ": " + ec.message());
    return;
  }
  std::sort(children.begin(), children.end());
  for (const auto& child : children) {
    collect(child, name + "/" + child.filename().native(), out, error);
    if (!error.ok()) return;
  }
}

}  // namespace

bool available() { return library().error.empty(); }
std::string error() { return library().error; }
const std::vector<Format>& formats() { return library().formats; }

const Format* find_format(const std::string& name) {
  for (const auto& f : library().formats)
    if (f.name == name) return &f;
  return nullptr;
}

void set_library_path(const Filepath& path) {
  std::lock_guard lock(g_path_mutex);
  g_requested_path = path;
}

Archive::Archive(std::unique_ptr<State> state) : _state(std::move(state)) {}
Archive::~Archive() = default;
const std::string& Archive::format() const { return _state->format; }
const std::vector<Entry>& Archive::entries() const { return _state->entries; }

Err Archive::open(const Filepath& file, const std::string& format, std::unique_ptr<Archive>& out, const PasswordSource& password,
                  const Progress& progress) {
  const auto& lib = library();
  if (!lib.error.empty()) return Err("Archive support is unavailable: " + lib.error);
  int error = 0;
  auto stream = InFile::open(file, error);
  if (!stream) return Err("cannot open " + file.native() + ": " + std::strerror(error));
  bool refused = false;
  for (const auto* h : candidates(file, format)) {
    if (progress.cancelled && progress.cancelled->load()) return Err("cancelled");
    ComPtr<IInArchive> handler;
    if (lib.create_object(&h->class_id, &IID_IInArchive, reinterpret_cast<void**>(handler.put())) != S_OK || !handler) continue;
    stream->Seek(0, STREAM_SEEK_SET, nullptr);
    ComPtr<OpenCallback> callback(new OpenCallback(password, progress));
    const UInt64 scan = 0;
    const HRESULT hr = handler->Open(stream.get(), &scan, callback.get());
    if (hr == S_OK) {
      auto state = std::make_unique<State>();
      state->handler = handler;
      state->stream = stream;
      state->format = h->format.name;
      read_entries(lib, handler.get(), file, state->entries);
      out.reset(new Archive(std::move(state)));
      return Err();
    }
    handler->Close();
    if (callback->password_refused()) refused = true;
    if (hr == E_ABORT && progress.cancelled && progress.cancelled->load()) return Err("cancelled");
  }
  if (refused) return Err("A password is needed to open " + file.native());
  return Err("Not an archive FC can open: " + file.native());
}

Err Archive::extract(const std::vector<uint32_t>& indices, const std::function<Filepath(const Entry&)>& output,
                     const std::function<void(const Entry&, Err)>& finished, const PasswordSource& password, const Progress& progress) {
  std::lock_guard lock(_state->mutex);
  std::vector<UInt32> sorted(indices.begin(), indices.end());
  std::sort(sorted.begin(), sorted.end());
  sorted.erase(std::unique(sorted.begin(), sorted.end()), sorted.end());
  for (auto i : sorted)
    if (i >= _state->entries.size()) return Err("no entry " + std::to_string(i) + " in the archive");
  if (sorted.empty()) return Err();
  ComPtr<ExtractCallback> callback(new ExtractCallback(_state->entries, output, finished, password, progress));
  const HRESULT hr = _state->handler->Extract(sorted.data(), UInt32(sorted.size()), 0, callback.get());
  if (hr != S_OK) {
    const std::string why = hr == E_ABORT && callback->password_refused() ? "a password is needed" : hresult_text(hr);
    callback->abandon(why);
    return Err("Extraction stopped: " + why);
  }
  return Err();
}

Err read_compressed_tar(const Filepath& file, const std::string& compression, const std::function<Filepath(const Entry&)>& output,
                        const std::function<void(const Entry&, Err)>& finished, const Progress& progress) {
  const auto& lib = library();
  if (!lib.error.empty()) return Err("Archive support is unavailable: " + lib.error);
  std::unique_ptr<Archive> outer;
  if (auto error = Archive::open(file, compression, outer, {}, progress); !error.ok()) return error;
  if (outer->entries().size() != 1) return Err("Not a compressed tar: " + file.native());
  const HandlerInfo* tar_info = nullptr;
  for (const auto& h : lib.handlers)
    if (h.format.name == "tar") tar_info = &h;
  if (!tar_info) return Err("7-Zip's library has no tar reader");
  ComPtr<IInArchive> tar;
  if (lib.create_object(&tar_info->class_id, &IID_IInArchive, reinterpret_cast<void**>(tar.put())) != S_OK || !tar)
    return Err("cannot create a tar reader");
  ComPtr<IArchiveOpenSeq> sequential;
  if (tar->QueryInterface(IID_IArchiveOpenSeq, reinterpret_cast<void**>(sequential.put())) != S_OK || !sequential)
    return Err("tar can't be read sequentially");
  auto pipe = std::make_shared<Pipe>(size_t(1) << 20);
  ComPtr<PipeReader> reader(new PipeReader(pipe));
  if (sequential->OpenSeq(reader.get()) != S_OK) return Err("cannot read a tar from " + file.native());
  // The compressed stream is decoded on its own thread, into the pipe tar reads from.
  ComPtr<PipeExtractCallback> producer(new PipeExtractCallback(pipe));
  HRESULT produced = S_OK;
  auto& state = *outer->_state;
  std::thread decoder([&] {
    UInt32 index = 0;
    {
      std::lock_guard lock(state.mutex);
      produced = state.handler->Extract(&index, 1, 0, producer.get());
    }
    pipe->close_writer();
  });
  ComPtr<SequentialTarCallback> consumer(new SequentialTarCallback(tar.get(), file, output, finished, progress, state.stream.get()));
  const HRESULT hr = tar->Extract(nullptr, UInt32(-1), 0, consumer.get());
  pipe->close_reader();  // Stops the decoder when tar ended before the stream did.
  decoder.join();
  tar->Close();
  if (hr != S_OK) {
    const auto why = progress.cancelled && progress.cancelled->load() ? std::string("cancelled") : hresult_text(hr);
    consumer->abandon(why);
    return Err("Extraction stopped: " + why);
  }
  if (produced == S_OK && producer->result != NArchive::NExtract::NOperationResult::kOK)
    return Err(file.native() + ": " + operation_result_text(producer->result));
  if (produced != S_OK && produced != E_ABORT) return Err("Extraction stopped: " + hresult_text(produced));
  return Err();
}

Err create(const std::string& format, const std::vector<NewItem>& items, const Filepath& destination, const Progress& progress) {
  const auto& lib = library();
  if (!lib.error.empty()) return Err("Archive support is unavailable: " + lib.error);
  const HandlerInfo* handler_info = nullptr;
  for (const auto& h : lib.handlers)
    if (h.format.name == format) handler_info = &h;
  if (!handler_info) return Err("unknown archive format: " + format);
  if (!handler_info->format.writable) return Err("FC can't create " + format + " archives");
  std::vector<Source> sources;
  Err error;
  for (const auto& item : items) {
    collect(item.source, item.name, sources, error);
    if (!error.ok()) return error;
  }
  ComPtr<IOutArchive> handler;
  if (lib.create_object(&handler_info->class_id, &IID_IOutArchive, reinterpret_cast<void**>(handler.put())) != S_OK || !handler)
    return Err("cannot create a " + format + " writer");
  int open_error = 0;
  auto file = OutFile::create(destination, open_error);
  if (!file) return Err("cannot create " + destination.native() + ": " + std::strerror(open_error));
  ComPtr<UpdateCallback> callback(new UpdateCallback(sources, progress));
  const HRESULT hr = handler->UpdateItems(file.get(), UInt32(sources.size()), callback.get());
  const int close_error = file->close();
  if (hr != S_OK) return Err("Archive creation stopped: " + (callback->error().empty() ? hresult_text(hr) : callback->error()));
  if (close_error != 0) return Err("cannot write " + destination.native() + ": " + std::strerror(close_error));
  return Err();
}

}  // namespace SevenZip
