#include "remote_fs.hpp"
#include <iostream>
#include <unistd.h>
void require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
int main(int argc,char** argv){
  std::string host=argc>1?argv[1]:"fixture";
  auto root=Location::decode("ssh://"+host+"/tmp/"+boost::filesystem::unique_path("fc-ssh-%%%%%%%%-%%%%%%%%").native()).resource();
  bool made=false;
  try{
    require(Location::decode(root.native()).ssh==host,"Host identity lost");
    require(location_parent(Location::decode("ssh://"+host+"/").resource())==Location::decode("ssh://"+host+"/").resource(),"Remote root escaped");
    RemoteFS::mkdir(root);made=true;
    auto a=root/"alpha file\n.txt",b=root/"beta.txt",link=root/"link";
    std::string text("remote\0bytes\n",13);RemoteFS::write(a,0,text,true);
    require(RemoteFS::read(a,0,100)==text,"Binary read/write failed");
    bool exclusive=false;try{RemoteFS::write(a,0,"bad",true);}catch(const std::system_error&){exclusive=true;}
    require(exclusive&&RemoteFS::read(a,0,100)==text,"Exclusive create overwrote a file");
    RemoteFS::symlink(a.filename().native(),link);
    require(RemoteFS::inspect(link).symlink(),"lstat followed a link");
    require(RemoteFS::inspect(link,true).size==int64_t(text.size()),"stat did not follow a link");
    auto entries=RemoteFS::list(root);require(entries.size()==2,"Directory listing lost entries");
    RemoteFS::rename(link,b);require(RemoteFS::inspect(b).symlink()&&RemoteFS::inspect(a).exists,"Rename moved a link target");
    RemoteFS::remove(b);require(RemoteFS::inspect(a).exists,"Delete removed a link target");
    RemoteFS::remove(root,true);made=false;RemoteFS::close_connections();
    std::cout<<"SSH filesystem contract passed on "<<host<<"\n";return 0;
  }catch(const std::exception& e){std::cerr<<e.what()<<"\n";if(made){try{RemoteFS::remove(root,true);}catch(...){}}return 1;}
}
