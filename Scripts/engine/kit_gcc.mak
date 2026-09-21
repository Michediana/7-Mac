PROG = 7zkit

# DEF_FILE makes 7zip_gcc.mak link a shared object rather than an executable,
# which is what lets us drop Alone2's console objects: there is no main() here.
# The .so itself is a by-product -- what we keep are the object files.
DEF_FILE = ../../Archive/Archive2.def

include ../Format7zF/Arc_gcc.mak

# Deliberately NOT -DZ7_EXTERNAL_CODECS. See LoadCodecs.h: with it defined,
# CCodecs::Load() goes hunting for 7z.so and Codecs/ Formats/ folders next to
# the executable. We are a standalone module with every codec linked in.
LOCAL_FLAGS = \
  $(LOCAL_FLAGS_ST) \

SYS_OBJS = \
  $O/MyWindows.o \
  $O/DLL.o \

# Our own TU, in place of upstream's UI/Console/Main.cpp: it defines the
# IID/CLSID constants. That is also why DllExports2.o and ArchiveExports.o are
# absent -- they would define the same GUIDs a second time.
KIT_OBJS = \
  $O/SevenZipKitInit.o \

COMMON_OBJS_2 = \
  $O/CommandLineParser.o \
  $O/ListFileUtils.o \
  $O/StdInStream.o \
  $O/StdOutStream.o \

# No SystemInfo.o: it is only there for the console's CPU banner, and it drags
# in Add_LargePages_String from Bench.cpp.
WIN_OBJS_2 = \
  $O/ErrorMsg.o \
  $O/FileLink.o \

7ZIP_COMMON_OBJS_2 = \
  $O/FilePathAutoRename.o \
  $O/FileStreams.o \
  $O/MultiOutStream.o \

UI_COMMON_OBJS = \
  $O/ArchiveExtractCallback.o \
  $O/ArchiveOpenCallback.o \
  $O/DefaultName.o \
  $O/EnumDirItems.o \
  $O/Extract.o \
  $O/ExtractingFilePath.o \
  $O/HashCalc.o \
  $O/LoadCodecs.o \
  $O/OpenArchive.o \
  $O/PropIDUtils.o \
  $O/SetProperties.o \
  $O/SortUtils.o \
  $O/TempFiles.o \
  $O/Update.o \
  $O/UpdateAction.o \
  $O/UpdateCallback.o \
  $O/UpdatePair.o \
  $O/UpdateProduce.o \

OBJS = \
  $(ARC_OBJS) \
  $(KIT_OBJS) \
  $(SYS_OBJS) \
  $(COMMON_OBJS_2) \
  $(WIN_OBJS_2) \
  $(7ZIP_COMMON_OBJS_2) \
  $(UI_COMMON_OBJS) \

include ../../7zip_gcc.mak

# 7zip_gcc.mak spells out a rule per object; ours lives in this directory.
$O/SevenZipKitInit.o: SevenZipKitInit.cpp
	$(CXX) $(CXXFLAGS) $<
