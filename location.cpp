#include "location.hpp"
#include <stdexcept>
namespace {
std::string escape(const std::string& text) {
  const char* hex="0123456789ABCDEF"; std::string out;
  for (unsigned char c:text) {
    if ((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_' || c=='-' || c=='.') out+=c;
    else {out+='%';out+=hex[c>>4];out+=hex[c&15];}
  }
  return out;
}
std::string unescape(const std::string& text) {
  auto digit=[](char c)->int { if (c>='0'&&c<='9') return c-'0'; if(c>='A'&&c<='F') return c-'A'+10; throw std::runtime_error("invalid archive location escape"); };
  std::string out;
  for(size_t i=0;i<text.size();++i) {
    char c=text[i]; if(c=='%') {if(i+2>=text.size()) throw std::runtime_error("invalid archive location"); c=char(digit(text[i+1])*16+digit(text[i+2]));i+=2;}
    if(!c) throw std::runtime_error("NUL in archive location"); out+=c;
  }
  return out;
}
void validate_relative(const Filepath& p) {
  if(p.is_absolute()) throw std::runtime_error("absolute internal archive path");
  for(const auto& part:p) if(part=="..") throw std::runtime_error("archive path escapes its root");
}
}
std::string Location::encode() const {
  if(!read_only()) return local.native();
  std::string out="fc-archive:";
  for(const auto& p:archives) out+=escape(p.native())+"!";
  return out+escape(internal.native());
}
std::string Location::display() const {
  if(!read_only()) return local.native();
  std::string out; for(const auto& p:archives) out+=p.native()+"!/";
  return out+(internal=="."?"":internal.native());
}
Location Location::decode(const std::string& text) {
  Location result;
  if(text.rfind("fc-archive:",0)!=0) { result.local=Filepath(text).lexically_normal(); return result; }
  size_t at=11,end;
  while((end=text.find('!',at))!=std::string::npos) { result.archives.emplace_back(unescape(text.substr(at,end-at))); at=end+1; }
  if(result.archives.empty() || !result.archives.front().is_absolute() || result.archives.size()>32) throw std::runtime_error("invalid archive location chain");
  for(size_t i=1;i<result.archives.size();++i) validate_relative(result.archives[i]);
  result.internal=unescape(text.substr(at)); validate_relative(result.internal); return result;
}
