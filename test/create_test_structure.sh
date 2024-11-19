# Create directories
mkdir dir1 dir2

# Create files in dir1
echo "This is file1" > dir1/file1.txt
echo "This is file2" > dir1/file2.txt

# Create files in dir2
echo "This is file3" > dir2/file3.txt

# Inside dir1, create a symbolic link to file3.txt in dir2 using a relative path
ln -s ../dir2/file3.txt dir1/relative_link_to_file3.txt

# Create a relative symbolic link to dir2 from the root directory
ln -s dir2 relative_link_to_dir2

# Get the absolute path of file3.txt
FILE3_PATH=$(realpath dir2/file3.txt)

# Create an absolute symbolic link to file3.txt in dir1
ln -s "$FILE3_PATH" dir1/absolute_link_to_file3.txt

# Create an absolute symbolic link to dir2
DIR2_PATH=$(realpath dir2)
ln -s "$DIR2_PATH" absolute_link_to_dir2

# In dir1, create a symbolic link that points to itself
ln -s self_link dir1/self_link

# In dir1, create a symbolic link that points back to dir1
ln -s ../dir1 dir1/cyclic_link_to_dir1

# Create a subdirectory in dir2
mkdir dir2/subdir1

# Create a symbolic link in subdir1 that points back to dir2
ln -s ../../dir2 dir2/subdir1/cyclic_link_to_dir2

# Hard links cannot be created for directories and cannot span across different file systems
# In dir1, create a hard link to file3.txt
ln dir2/file3.txt dir1/hard_link_to_file3.txt

# tree -l          
# ├── absolute_link_to_dir2 -> /private/tmp/gen/dir2
# │   ├── file3.txt
# │   └── subdir1
# │       └── cyclic_link_to_dir2 -> ../../dir2  [recursive, not followed]
# ├── dir1
# │   ├── absolute_link_to_file3.txt -> /private/tmp/gen/dir2/file3.txt
# │   ├── cyclic_link_to_dir1 -> ../dir1  [recursive, not followed]
# │   ├── file1.txt
# │   ├── file2.txt
# │   ├── hard_link_to_file3.txt
# │   ├── relative_link_to_file3.txt -> ../dir2/file3.txt
# │   └── self_link -> self_link
# ├── dir2
# │   ├── file3.txt
# │   └── subdir1
# │       └── cyclic_link_to_dir2 -> ../../dir2  [recursive, not followed]
# └── relative_link_to_dir2 -> dir2  [recursive, not followed]
