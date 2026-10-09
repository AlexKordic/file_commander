# Third-party software

FC's original code is licensed under [MIT](LICENSE). This grant does not
replace the licenses of dependencies or vendored files. Existing copyright
notices in third-party source must be retained.

| Component | Version/source | Terms | License copy |
| --- | --- | --- | --- |
| Boost, including the modified `boost/filesystem` subtree | Boost 1.90.0; subtree at the FC revision | Boost Software License 1.0 | [BSL-1.0](licenses/boost/LICENSE_1_0.txt) |
| Modified FTXUI | Exact commit in `dependencies.json`; [FC fork](https://github.com/AlexKordic/FTXUI) | MIT, copyright Arthur Sonzogni | [MIT](licenses/ftxui/LICENSE) |
| LuaJIT, including incorporated Lua and dlmalloc code | Exact commit in `dependencies.json`; [upstream](https://github.com/LuaJIT/LuaJIT) | MIT for LuaJIT/Lua; public domain for dlmalloc | [Complete upstream notices](licenses/luajit/COPYRIGHT) |
| LZMA SDK / 7zr | SDK 26.00; fingerprinted source snapshot in `dependencies/` | Public domain; Igor Pavlov and the additional authors named upstream | [SDK statement](licenses/lzma-sdk/lzma-sdk.txt) |
| Fresh editor | Exact commit and integration bundle in `dependencies.json`; [FC fork](https://github.com/AlexKordic/fresh), [upstream](https://github.com/sinelaw/fresh) | GPL-3.0-or-later; embedded assets and Rust dependencies retain their own terms | [GPLv3](licenses/fresh/LICENSE) |

FC starts Fresh as a separate executable and communicates with it through its
command-line/session interface. It does not link Fresh code into `fc`. FC's MIT
license does not license `fresh`, its remote agent, or its dependencies under MIT.
The separate-program distribution must preserve users' rights under each
component's license; see GPLv3's discussion of aggregates in
[section 5](https://www.gnu.org/licenses/gpl-3.0.html#section5).

## Source publication and binary releases

The pinned commits, checksum-verified SDK source, modified Boost subtree, and
Fresh integration bundle identify the source inputs. The bundle is additional
Git history, not a complete standalone Fresh source archive.

Before publishing binaries containing Fresh, provide the corresponding source
for that exact version, including modified source, build scripts, lockfile and
the non-system dependency sources needed to build it. Publish that archive
alongside the binary download, with clear source instructions, as described in
[GPLv3 section 6](https://www.gnu.org/licenses/gpl-3.0.html#section6).
An upstream URL and a patch bundle alone are not our binary-release procedure.

The distribution includes FC's license, this inventory, the dependency notices,
Fresh's separate asset notices, and the source instructions. Rust crate
attributions also need review for the exact default-feature `fresh-editor`
build and target; some published crates omit separate license files. Do not
interpret the top-level inventory as a completed transitive-license audit.
See [the publication review and release plan](doc/open_source_release.md).
