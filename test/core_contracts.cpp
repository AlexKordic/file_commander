#include "support/contracts.hpp"
#include "location.hpp"
#include "settings.hpp"
#include "traversal.hpp"
#include "application_events.hpp"
#include "file_io_jobs.hpp"
#include <algorithm>
#include <iostream>
#include <map>
#include <random>
using namespace test;
using namespace Perun;
template<class F> void rejects(F fn,const std::string& message){bool rejected=false;try{fn();}catch(const std::exception&){rejected=true;}require(rejected,message);}
void locations(){
  std::mt19937 rng(0xFC2026);std::string alphabet="abcXYZ 09!%'\n_-";
  for(int i=0;i<256;++i){std::string name="Ω";for(int j=0;j<30;++j)name+=alphabet[rng()%alphabet.size()];
    Location value;value.archives={Filepath("/tmp")/name,Filepath("nested")/name};value.internal=Filepath("dir")/name;
    require(Location::decode(value.encode())==value,"generated location round trip seed FC2026 case "+std::to_string(i));
    Location local;local.local=Filepath("/tmp")/name;require(Location::decode(local.encode())==local,"local round trip");}
  for(size_t depth:{31,32,33}){Location value;value.archives.push_back("/a.7z");for(size_t i=1;i<depth;++i)value.archives.push_back("a.7z");
    if(depth<=32)require(Location::decode(value.encode())==value,"valid chain rejected");else rejects([&]{Location::decode(value.encode());},"oversized chain accepted");}
  for(auto bad:{"fc-archive:","fc-archive:relative!", "fc-archive:%2Fouter!%00", "fc-archive:%2Fouter!%", "fc-archive:%2Fouter!%GG", "fc-archive:%2Fouter!%2Fabsolute", "fc-archive:%2Fouter!..%2Fescape", "fc-archive:%2Fouter!..!"})
    rejects([&]{Location::decode(bad);},std::string("malformed location accepted: ")+bad);
  require(Location::decode("/a/./b/../c").local==Filepath("/a/c"),"local normalization");
}
void settings(){
  Fixture f;AppSettings s;s.left={"/left",Orderby::TIME_DESC,true,true};s.right={"/right",Orderby::SIZE_ASC,false,true};s.single_panel=true;s.focused_panel="right";
  s.bookmarks={"/space ' Ω","fc-archive:%2Fa.7z!nested"};s.command_use_count={{"Copy",0},{"Move",2147483647}};s.key_bindings={{"Copy","f8"}};s.fresh_binary_path="/quoted ' editor";s.last_editor_session_id="session Ω";
  SettingsStore::save(f/"settings",s);auto loaded=SettingsStore::load(f/"settings");require(loaded.has_value(),"saved settings missing");auto& v=*loaded;
  require(v.left.path==s.left.path&&v.left.sort==s.left.sort&&v.left.permissions&&v.left.owner_group&&v.right.path==s.right.path&&v.right.sort==s.right.sort&&!v.right.permissions&&v.right.owner_group,"panel round trip");
  require(v.single_panel&&v.focused_panel=="right"&&v.bookmarks==s.bookmarks&&v.key_bindings==s.key_bindings&&v.command_use_count==s.command_use_count&&v.fresh_binary_path==s.fresh_binary_path&&v.last_editor_session_id==s.last_editor_session_id,"settings fields lost");
  require(!SettingsStore::load(f/"missing"),"missing config is not normal");
  for(auto json:{"[", "[]", "{\"version\":2}","{\"left_sort\":\"bogus\"}","{\"focused_panel\":\"middle\"}","{\"single_panel_mode\":0}","{\"bookmarks\":[3]}","{\"key_bindings\":{\"Copy\":false}}","{\"command_use_count\":{\"Copy\":-1}}","{\"command_use_count\":{\"Copy\":2147483648}}"}){
    write(f/"bad",json);rejects([&]{SettingsStore::load(f/"bad");},"malformed settings accepted");require(read(f/"bad")==json,"load modified bad settings");}
  for(size_t size:{4*1024*1024-1,4*1024*1024,4*1024*1024+1}){write(f/"size","{}"+std::string(size-2,' '));if(size<=4*1024*1024)require(SettingsStore::load(f/"size").has_value(),"size boundary rejected");else rejects([&]{SettingsStore::load(f/"size");},"oversized settings accepted");}
}
void directory(){
  Dir dir;std::map<std::string,std::pair<int64_t,bool>> model;std::mt19937 rng(0xD1FF);
  auto item=[](std::string name,int64_t bytes){return DirItem(Filepath("/model")/name,name,fs::regular_file,fs::owner_read,bytes,bytes);};
  dir.publish({"/model",{}});
  for(int step=0;step<600;++step){std::string name=(rng()%2?"keep":"drop")+std::to_string(rng()%40);int action=rng()%4;
    if(action==0){dir.publish_delta({{Filepath("/model")/name,{}}});model.erase(name);}
    else if(action==1){auto i=std::find_if(dir.items.begin(),dir.items.end(),[&](const auto& v){return v.filename_ref()==name;});if(i!=dir.items.end()){dir.item_toggle_select(i-dir.items.begin());model[name].second=!model[name].second;}}
    else {int bytes=rng()%1024;bool selected=model.contains(name)&&model[name].second;model[name]={bytes,selected};dir.publish_delta({{Filepath("/model")/name,item(name,bytes)}});}
    dir.apply_filter(step%2?"keep":"");int64_t total=0,selected=0,selected_bytes=0,visible=0;
    for(auto&[n,v]:model){total+=v.first;selected+=v.second;selected_bytes+=v.second?v.first:0;visible+=step%2?n.starts_with("keep"):1;}
    auto stats=dir.stats();require(stats.items_total==model.size()&&stats.bytes_total==total&&stats.items_selected==selected&&stats.bytes_selected==selected_bytes&&stats.items_visible==visible,"directory delta model seed D1FF step "+std::to_string(step));
    for(const auto& v:dir.items)require(model.at(v.filename_ref())==std::pair<int64_t,bool>(v.size(),v.selected()),"delta item/selection differs");
  }
  for(int order=0;order<6;++order){dir.order_by=static_cast<Orderby>(order);dir._sort();
    for(size_t i=1;i<dir.items.size();++i){const auto&a=dir.items[i-1];const auto&b=dir.items[i];bool asc=order%2==0;
      require(order<2?(asc?a.filename_ref()<=b.filename_ref():a.filename_ref()>=b.filename_ref()):order<4?(asc?a.size()<=b.size():a.size()>=b.size()):(asc?a.write_time()<=b.write_time():a.write_time()>=b.write_time()),"sort contract");}}
  dir.clear_selection();require(dir.stats().items_selected==0&&dir.stats().bytes_selected==0,"clear selection counters");
}
void traversal(){
  Fixture f;fs::create_directories(f/"a/b/c");write(f/"a/b/c/file","payload");
  for(size_t limit:{0,3,4,5}){TraversalPolicy p;p.max_depth=limit;auto r=traverse({f/"a"},p,{});require(r.entries==std::min(limit,size_t{4})&&r.truncated==(limit<4),"depth limit boundary");}
  for(size_t limit:{0,3,4,5}){TraversalPolicy p;p.max_entries=limit;auto r=traverse({f/"a"},p,{});require(r.entries==std::min(limit,size_t{4})&&r.truncated==(limit<4),"entry limit boundary");}
  std::vector<Filepath> stack;TraversalCallbacks cb;cb.enter=[&](const auto&e){stack.push_back(e.path);return true;};cb.leave=[&](const auto&e){require(!stack.empty()&&stack.back()==e.path,"postorder mismatch");stack.pop_back();};auto r=traverse({f/"a"},{},cb);require(!r.errors&&stack.empty(),"traversal postorder missing");
  fs::create_symlink("../..",f/"a/b/c/cycle");TraversalPolicy follow;follow.follow_links=true;int duplicates=0;cb={};cb.enter=[&](const auto&e){duplicates+=e.duplicate_of.has_value();return true;};r=traverse({f/"a",f/"a/b"},follow,cb);require(!r.truncated&&!r.errors&&duplicates==2,"overlap/cycle aliases not bounded");
  bool cancelled=false;cb={};cb.enter=[&](const auto&){cancelled=true;return true;};cb.cancelled=[&]{return cancelled;};r=traverse({f/"a"},{},cb);require(r.cancelled&&r.entries==1,"traversal cancellation ignored");
  r=traverse({f/"absent"},{},{});require(r.errors==1,"missing root error lost");
}
void events(){
  for(int count:{4095,4096,4097}){ApplicationEvents events;for(int i=1;i<=count;++i)events.publish("event",std::to_string(i),i);
    uint64_t first=0,second=0;auto a=events.since(first),b=events.since(second);require(a.size()==b.size()&&first==count&&second==count,"subscriber cursors interfere");
    bool expired=count>4096;require(a.size()==std::min(count,4096)+expired,"event retention bound");if(expired)require(a.front().name=="event_history_expired","subscriber not told to resynchronize");
    for(size_t i=expired;i<a.size();++i)require(a[i].detail==std::to_string(a[i].request_id)&&a[i].sequence==a[i].request_id,"event identity mismatch");require(events.since(first).empty(),"consumed event replayed");events.publish("next");require(events.since(second).size()==1,"independent cursor lost event");}
}
void retention(){
  for(size_t history:{0,1,2})for(size_t details:{0,1,2}){JobRetention limits;limits.history_count=history;limits.detail_count=details;limits.detail_bytes=1024;limits.event_count=2;limits.error_count=2;
    auto jobs=make_file_jobs(limits);for(int i=0;i<3;++i){auto plan=std::make_shared<OperationPlan>();plan->steps.push_back({Operation::Kind::DiscoveryFailure,"/fixture",{},{},std::string(2048,'e')});auto job=std::make_shared<JobSpec>(plan);jobs->add_job(job);until([&]{return jobs->idle();},"retention timeout");}
    auto retained=jobs->get_job_history();require(retained.size()==history,"history boundary");for(auto& job:retained){auto v=job->snapshot();require(v->_details_expired&&v->_items.empty()&&v->_error_count==1&&v->_items_done==1,"positive byte eviction lost summary");}
    uint64_t cursor=0;auto events=jobs->events_since(cursor);require(events.size()==3&&events[0].history_expired,"job event expiry");require(jobs->get_errors(100).size()<=2,"errors exceeded budget");}
  JobRetention limits;limits.detail_bytes=1024*1024;limits.detail_count=1;auto jobs=make_file_jobs(limits);auto plan=std::make_shared<OperationPlan>();plan->steps.push_back({Operation::Kind::DiscoveryFailure,"/fixture",{},{},"expected"});auto job=std::make_shared<JobSpec>(plan);jobs->add_job(job);until([&]{return jobs->idle();},"retained detail timeout");require(!job->snapshot()->_details_expired&&!job->snapshot()->_errors.empty(),"positive detail budget evicted small payload");
  Fixture f;fs::create_directory(f/"extracted");write(f/"extracted/source","leased bytes");
  auto lease=std::make_shared<ArchiveRoot>(f/"extracted");Gate gate;FileJobServices services;services.clipboard=[&](const auto&){gate.arrive();return Err();};auto queued=make_file_jobs({},services);Gate::Release release{gate};
  auto block_plan=std::make_shared<OperationPlan>();block_plan->type=OperationType::CLIPBOARD;block_plan->steps.push_back({Operation::Kind::ClipboardText});queued->add_job(std::make_shared<JobSpec>(block_plan));gate.await();
  auto copy_plan=std::make_shared<OperationPlan>();copy_plan->steps.push_back({Operation::Kind::CopyFile,f/"extracted/source",f/"copied"});auto copy=std::make_shared<JobSpec>(copy_plan);copy->_archive_leases.push_back(lease);queued->add_job(copy);lease.reset();require(fs::exists(f/"extracted/source"),"queued lease lost before execution");gate.open();until([&]{return queued->idle();},"leased copy timeout");require(read(f/"copied")=="leased bytes"&&!fs::exists(f/"extracted"),"completed job did not release archive lease");

}
void typed(){
  Fixture f;auto jobs=make_file_jobs();
  auto run=[&](OperationType type,std::vector<Operation> ops,bool success=true){auto plan=std::make_shared<OperationPlan>();plan->type=type;plan->steps=std::move(ops);auto job=std::make_shared<JobSpec>(plan);jobs->add_job(job);until([&]{return jobs->idle();},"typed operation timeout");require(job->_state==(success?JobState::COMPLETED:JobState::COMPLETED_WITH_ERRORS),"typed operation outcome");return job->snapshot();};
  auto mkdir=Operation{Operation::Kind::CreateDirectory,{},f/"directory"};require(run(OperationType::MKDIR,{mkdir})->_items_done==1&&fs::is_directory(f/"directory"),"typed mkdir");require(run(OperationType::MKDIR,{mkdir},false)->_items_failed==1,"mkdir conflict");
  write(f/"source","typed bytes");run(OperationType::COPY,{{Operation::Kind::CopyFile,f/"source",f/"directory/copy",{},"",11}});require(read(f/"directory/copy")=="typed bytes","typed copy bytes");
  run(OperationType::COPY,{{Operation::Kind::CreateSymlink,{},f/"link","source"}});require(fs::read_symlink(f/"link")==Filepath("source"),"typed raw link");
  run(OperationType::RENAME,{{Operation::Kind::RenameEntry,f/"source",f/"renamed"}});require(!fs::exists(f/"source")&&read(f/"renamed")=="typed bytes","typed rename");
  run(OperationType::RENAME,{{Operation::Kind::RenameEntry,f/"missing",f/"target"}},false);
  run(OperationType::MOVE,{{Operation::Kind::MoveEntry,f/"renamed",f/"moved"}});require(!fs::exists(f/"renamed")&&read(f/"moved")=="typed bytes","typed move");
  run(OperationType::DELETE,{{Operation::Kind::DeleteEntry,f/"link"}});require(!fs::is_symlink(f/"link")&&fs::exists(f/"moved"),"typed delete link");
  run(OperationType::COPY,{{Operation::Kind::DiscoveryFailure,f/"missing",{},{},"discovery fixture failure"}},false);
  FileJobServices services;std::string copied;services.clipboard=[&](const auto&text){copied=text;return Err();};auto clipboard=make_file_jobs({},services);auto plan=std::make_shared<OperationPlan>();plan->type=OperationType::CLIPBOARD;plan->steps.push_back({Operation::Kind::ClipboardText,{},{},{},"exact\ntext"});auto job=std::make_shared<JobSpec>(plan);clipboard->add_job(job);until([&]{return clipboard->idle();},"clipboard timeout");require(copied=="exact\ntext"&&job->_state==JobState::COMPLETED,"typed clipboard");
}
int main(int argc,char**argv){try{require(argc==2,"one core contract ID required");std::string name=argv[1];bool found=false;
#define RUN(n) if(name==#n){n();found=true;}
RUN(locations) RUN(settings) RUN(directory) RUN(traversal) RUN(events) RUN(retention) RUN(typed)
require(found,"unknown core contract");std::cout<<"PASS core "<<name<<"\n";}catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 1;}}
