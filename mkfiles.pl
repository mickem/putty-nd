#!/usr/bin/env perl
#
# Makefile generator for PuTTY.
#
# Reads the file `Recipe' to determine the list of generated
# executables and their component objects. Then reads the source
# files to compute #include dependencies. Finally, writes out the
# various target Makefiles.

use FileHandle;

open IN, "Recipe" or do {
    # We want to deal correctly with being run from one of the
    # subdirs in the source tree. So if we can't find Recipe here,
    # try one level up.
    chdir "..";
    open IN, "Recipe" or die "unable to open Recipe file\n";
};

# HACK: One of the source files in `charset' is auto-generated by
# sbcsgen.pl. We need to generate that _now_, before attempting
# dependency analysis.
eval 'chdir "charset"; require "sbcsgen.pl"; chdir ".."';

@incdirs = ("", "charset/", "unix/", "mac/");

$help = ""; # list of newline-free lines of help text
%programs = (); # maps prog name + type letter to listref of objects/resources
%groups = (); # maps group name to listref of objects/resources

while (<IN>) {
  # Skip comments (unless the comments belong, for example because
  # they're part of the help text).
  next if /^\s*#/ and !$in_help;

  chomp;
  split;
  if ($_[0] eq "!begin" and $_[1] eq "help") { $in_help = 1; next; }
  if ($_[0] eq "!end" and $in_help) { $in_help = 0; next; }
  # If we're gathering help text, keep doing so.
  if ($in_help) { $help .= "$_\n"; next; }
  # Ignore blank lines.
  next if scalar @_ == 0;

  # Now we have an ordinary line. See if it's an = line, a : line
  # or a + line.
  @objs = @_;

  if ($_[0] eq "+") {
    $listref = $lastlistref;
    $prog = undef;
    die "$.: unexpected + line\n" if !defined $lastlistref;
  } elsif ($_[1] eq "=") {
    $groups{$_[0]} = [] if !defined $groups{$_[0]};
    $listref = $groups{$_[0]};
    $prog = undef;
    shift @objs; # eat the group name
  } elsif ($_[1] eq ":") {
    $listref = [];
    $prog = $_[0];
    shift @objs; # eat the program name
  } else {
    die "$.: unrecognised line type\n";
  }
  shift @objs; # eat the +, the = or the :

  while (scalar @objs > 0) {
    $i = shift @objs;
    if ($groups{$i}) {
      foreach $j (@{$groups{$i}}) { unshift @objs, $j; }
    } elsif (($i eq "[G]" or $i eq "[C]" or $i eq "[M]" or
	      $i eq "[X]" or $i eq "[U]") and defined $prog) {
      $type = substr($i,1,1);
    } else {
      push @$listref, $i;
    }
  }
  if ($prog and $type) {
    die "multiple program entries for $prog [$type]\n"
	if defined $programs{$prog . "," . $type};
    $programs{$prog . "," . $type} = $listref;
  }
  $lastlistref = $listref;
}

close IN;

# Now retrieve the complete list of objects and resource files, and
# construct dependency data for them. While we're here, expand the
# object list for each program, and complain if its type isn't set.
@prognames = sort keys %programs;
%depends = ();
@scanlist = ();
foreach $i (@prognames) {
  ($prog, $type) = split ",", $i;
  # Strip duplicate object names.
  $prev = undef;
  @list = grep { $status = ($prev ne $_); $prev=$_; $status }
          sort @{$programs{$i}};
  $programs{$i} = [@list];
  foreach $j (@list) {
    # Dependencies for "x" start with "x.c".
    # Dependencies for "x.res" start with "x.rc".
    # Dependencies for "x.rsrc" start with "x.r".
    # Both types of file are pushed on the list of files to scan.
    # Libraries (.lib) don't have dependencies at all.
    if ($j =~ /^(.*)\.res$/) {
      $file = "$1.rc";
      $depends{$j} = [$file];
      push @scanlist, $file;
    } elsif ($j =~ /^(.*)\.rsrc$/) {
      $file = "$1.r";
      $depends{$j} = [$file];
      push @scanlist, $file;
    } elsif ($j =~ /\.lib$/) {
      # libraries don't have dependencies
    } else {
      $file = "$j.c";
      $depends{$j} = [$file];
      push @scanlist, $file;
    }
  }
}

# Scan each file on @scanlist and find further inclusions.
# Inclusions are given by lines of the form `#include "otherfile"'
# (system headers are automatically ignored by this because they'll
# be given in angle brackets). Files included by this method are
# added back on to @scanlist to be scanned in turn (if not already
# done).
#
# Resource scripts (.rc) can also include a file by means of a line
# ending `ICON "filename"'. Files included by this method are not
# added to @scanlist because they can never include further files.
#
# In this pass we write out a hash %further which maps a source
# file name into a listref containing further source file names.

%further = ();
while (scalar @scanlist > 0) {
  $file = shift @scanlist;
  next if defined $further{$file}; # skip if we've already done it
  $resource = ($file =~ /\.rc$/ ? 1 : 0);
  $further{$file} = [];
  $dirfile = &findfile($file);
  open IN, "$dirfile" or die "unable to open source file $file\n";
  while (<IN>) {
    chomp;
    /^\s*#include\s+\"([^\"]+)\"/ and do {
      push @{$further{$file}}, $1;
      push @scanlist, $1;
      next;
    };
    /ICON\s+\"([^\"]+)\"\s*$/ and do {
      push @{$further{$file}}, $1;
      next;
    }
  }
  close IN;
}

# Now we're ready to generate the final dependencies section. For
# each key in %depends, we must expand the dependencies list by
# iteratively adding entries from %further.
foreach $i (keys %depends) {
  %dep = ();
  @scanlist = @{$depends{$i}};
  foreach $i (@scanlist) { $dep{$i} = 1; }
  while (scalar @scanlist > 0) {
    $file = shift @scanlist;
    foreach $j (@{$further{$file}}) {
      if ($dep{$j} != 1) {
        $dep{$j} = 1;
	push @{$depends{$i}}, $j;
	push @scanlist, $j;
      }
    }
  }
#  printf "%s: %s\n", $i, join ' ',@{$depends{$i}};
}

# Utility routines while writing out the Makefiles.

sub findfile {
  my ($name) = @_;
  my $dir, $i, $outdir = "";
  unless (defined $findfilecache{$name}) {
    $i = 0;
    foreach $dir (@incdirs) {
      $outdir = $dir, $i++ if -f "$dir$name";
    }
    die "multiple instances of source file $name\n" if $i > 1;
    $findfilecache{$name} = $outdir . $name;
  }
  return $findfilecache{$name};
}

sub objects {
  my ($prog, $otmpl, $rtmpl, $ltmpl, $prefix, $dirsep) = @_;
  my @ret;
  my ($i, $x, $y);
  @ret = ();
  foreach $i (@{$programs{$prog}}) {
    $x = "";
    if ($i =~ /^(.*)\.(res|rsrc)/) {
      $y = $1;
      ($x = $rtmpl) =~ s/X/$y/;
    } elsif ($i =~ /^(.*)\.lib/) {
      $y = $1;
      ($x = $ltmpl) =~ s/X/$y/;
    } else {
      ($x = $otmpl) =~ s/X/$i/;
    }
    push @ret, $x if $x ne "";
  }
  return join " ", @ret;
}

sub splitline {
  my ($line, $width, $splitchar) = @_;
  my ($result, $len);
  $len = (defined $width ? $width : 76);
  $splitchar = (defined $splitchar ? $splitchar : '\\');
  while (length $line > $len) {
    $line =~ /^(.{0,$len})\s(.*)$/ or $line =~ /^(.{$len,}?\s(.*)$/;
    $result .= $1 . " ${splitchar}\n\t\t";
    $line = $2;
    $len = 60;
  }
  return $result . $line;
}

sub deps {
  my ($otmpl, $rtmpl, $prefix, $dirsep, $depchar, $splitchar) = @_;
  my ($i, $x, $y);
  my @deps, @ret;
  @ret = ();
  $depchar ||= ':';
  foreach $i (sort keys %depends) {
    if ($i =~ /^(.*)\.(res|rsrc)/) {
      next if !defined $rtmpl;
      $y = $1;
      ($x = $rtmpl) =~ s/X/$y/;
    } else {
      ($x = $otmpl) =~ s/X/$i/;
    }
    @deps = @{$depends{$i}};
    @deps = map {
      $_ = &findfile($_);
      s/\//$dirsep/g;
      $_ = $prefix . $_;
    } @deps;
    push @ret, {obj => $x, deps => [@deps]};
  }
  return @ret;
}

sub prognames {
  my ($types) = @_;
  my ($n, $prog, $type);
  my @ret;
  @ret = ();
  foreach $n (@prognames) {
    ($prog, $type) = split ",", $n;
    push @ret, $n if index($types, $type) >= 0;
  }
  return @ret;
}

sub progrealnames {
  my ($types) = @_;
  my ($n, $prog, $type);
  my @ret;
  @ret = ();
  foreach $n (@prognames) {
    ($prog, $type) = split ",", $n;
    push @ret, $prog if index($types, $type) >= 0;
  }
  return @ret;
}

sub manpages {
  my ($types,$suffix) = @_;

  # assume that all UNIX programs have a man page
  if($suffix eq "1" && $types =~ /X/) {
    return map("$_.1", &progrealnames($types));
  }
  return ();
}

# Now we're ready to output the actual Makefiles.

##-- CygWin makefile
open OUT, ">Makefile.cyg"; select OUT;
print
"# Makefile for PuTTY under cygwin.\n".
"#\n# This file was created by `mkfiles.pl' from the `Recipe' file.\n".
"# DO NOT EDIT THIS FILE DIRECTLY; edit Recipe or mkfiles.pl instead.\n";
# gcc command line option is -D not /D
($_ = $help) =~ s/=\/D/=-D/gs;
print $_;
print
"\n".
"# You can define this path to point at your tools if you need to\n".
"# TOOLPATH = c:\\cygwin\\bin\\ # or similar, if you're running Windows\n".
"# TOOLPATH = /pkg/mingw32msvc/i386-mingw32msvc/bin/\n".
"CC = \$(TOOLPATH)gcc\n".
"RC = \$(TOOLPATH)windres\n".
"# Uncomment the following two lines to compile under Winelib\n".
"# CC = winegcc\n".
"# RC = wrc\n".
"# You may also need to tell windres where to find include files:\n".
"# RCINC = --include-dir c:\\cygwin\\include\\\n".
"\n".
&splitline("CFLAGS = -mno-cygwin -Wall -O2 -D_WINDOWS -DDEBUG -DWIN32S_COMPAT".
  " -D_NO_OLDNAMES -DNO_MULTIMON -I.")."\n".
"LDFLAGS = -mno-cygwin -s\n".
&splitline("RCFLAGS = \$(RCINC) --define WIN32=1 --define _WIN32=1".
  " --define WINVER=0x0400 --define MINGW32_FIX=1")."\n".
"\n".
".SUFFIXES:\n".
"\n".
"%.o: %.c\n".
"\t\$(CC) \$(COMPAT) \$(FWHACK) \$(XFLAGS) \$(CFLAGS) -c \$<\n".
"\n".
"%.res.o: %.rc\n".
"\t\$(RC) \$(FWHACK) \$(RCFL) \$(RCFLAGS) \$< \$\@\n".
"\n";
print &splitline("all:" . join "", map { " $_.exe" } &progrealnames("GC"));
print "\n\n";
foreach $p (&prognames("GC")) {
  ($prog, $type) = split ",", $p;
  $objstr = &objects($p, "X.o", "X.res.o", undef);
  print &splitline($prog . ".exe: " . $objstr), "\n";
  my $mw = $type eq "G" ? " -mwindows" : "";
  $libstr = &objects($p, undef, undef, "-lX");
  print &splitline("\t\$(CC)" . $mw . " \$(LDFLAGS) -o \$@ " .
                   $objstr . " $libstr", 69), "\n\n";
}
foreach $d (&deps("X.o", "X.res.o", "", "/")) {
  print &splitline(sprintf("%s: %s", $d->{obj}, join " ", @{$d->{deps}})),
    "\n";
}
print
"\n".
"version.o: FORCE;\n".
"# Hack to force version.o to be rebuilt always\n".
"FORCE:\n".
"\t\$(CC) \$(COMPAT) \$(FWHACK) \$(XFLAGS) \$(CFLAGS) \$(VER) -c version.c\n".
"clean:\n".
"\trm -f *.o *.exe *.res.o\n".
"\n";
select STDOUT; close OUT;

##-- Borland makefile
%stdlibs = (  # Borland provides many Win32 API libraries intrinsically
  "advapi32" => 1,
  "comctl32" => 1,
  "comdlg32" => 1,
  "gdi32" => 1,
  "imm32" => 1,
  "shell32" => 1,
  "user32" => 1,
  "winmm" => 1,
  "winspool" => 1,
  "wsock32" => 1,
);	    
open OUT, ">Makefile.bor"; select OUT;
print
"# Makefile for PuTTY under Borland C.\n".
"#\n# This file was created by `mkfiles.pl' from the `Recipe' file.\n".
"# DO NOT EDIT THIS FILE DIRECTLY; edit Recipe or mkfiles.pl instead.\n";
# bcc32 command line option is -D not /D
($_ = $help) =~ s/=\/D/=-D/gs;
print $_;
print
"\n".
"# If you rename this file to `Makefile', you should change this line,\n".
"# so that the .rsp files still depend on the correct makefile.\n".
"MAKEFILE = Makefile.bor\n".
"\n".
"# C compilation flags\n".
"CFLAGS = -D_WINDOWS -DWINVER=0x0401\n".
"\n".
"# Get include directory for resource compiler\n".
"!if !\$d(BCB)\n".
"BCB = \$(MAKEDIR)\\..\n".
"!endif\n".
"\n".
".c.obj:\n".
&splitline("\tbcc32 -w-aus -w-ccc -w-par -w-pia \$(COMPAT) \$(FWHACK)".
  " \$(XFLAGS) \$(CFLAGS) /c \$*.c",69)."\n".
".rc.res:\n".
&splitline("\tbrcc32 \$(FWHACK) \$(RCFL) -i \$(BCB)\\include -r".
  " -DNO_WINRESRC_H -DWIN32 -D_WIN32 -DWINVER=0x0401 \$*.rc",69)."\n".
"\n";
print &splitline("all:" . join "", map { " $_.exe" } &progrealnames("GC"));
print "\n\n";
foreach $p (&prognames("GC")) {
  ($prog, $type) = split ",", $p;
  $objstr = &objects($p, "X.obj", "X.res", undef);
  print &splitline("$prog.exe: " . $objstr . " $prog.rsp"), "\n";
  my $ap = ($type eq "G") ? "-aa" : "-ap";
  print "\tilink32 $ap -Gn -L\$(BCB)\\lib \@$prog.rsp\n\n";
}
foreach $p (&prognames("GC")) {
  ($prog, $type) = split ",", $p;
  print $prog, ".rsp: \$(MAKEFILE)\n";
  $objstr = &objects($p, "X.obj", undef, undef);
  @objlist = split " ", $objstr;
  @objlines = ("");
  foreach $i (@objlist) {
    if (length($objlines[$#objlines] . " $i") > 50) {
      push @objlines, "";
    }
    $objlines[$#objlines] .= " $i";
  }
  $c0w = ($type eq "G") ? "c0w32" : "c0x32";
  print "\techo $c0w + > $prog.rsp\n";
  for ($i=0; $i<=$#objlines; $i++) {
    $plus = ($i < $#objlines ? " +" : "");
    print "\techo$objlines[$i]$plus >> $prog.rsp\n";
  }
  print "\techo $prog.exe >> $prog.rsp\n";
  $objstr = &objects($p, "X.obj", "X.res", undef);
  @libs = split " ", &objects($p, undef, undef, "X");
  @libs = grep { !$stdlibs{$_} } @libs;
  unshift @libs, "cw32", "import32";
  $libstr = join ' ', @libs;
  print "\techo nul,$libstr, >> $prog.rsp\n";
  print "\techo " . &objects($p, undef, "X.res", undef) . " >> $prog.rsp\n";
  print "\n";
}
foreach $d (&deps("X.obj", "X.res", "", "\\")) {
  print &splitline(sprintf("%s: %s", $d->{obj}, join " ", @{$d->{deps}})),
    "\n";
}
print
"\n".
"version.o: FORCE\n".
"# Hack to force version.o to be rebuilt always\n".
"FORCE:\n".
"\tbcc32 \$(FWHACK) \$(VER) \$(CFLAGS) /c version.c\n\n".
"clean:\n".
"\t-del *.obj\n".
"\t-del *.exe\n".
"\t-del *.res\n".
"\t-del *.pch\n".
"\t-del *.aps\n".
"\t-del *.il*\n".
"\t-del *.pdb\n".
"\t-del *.rsp\n".
"\t-del *.tds\n".
"\t-del *.\$\$\$\$\$\$\n";
select STDOUT; close OUT;

##-- Visual C++ makefile
open OUT, ">Makefile.vc"; select OUT;
print
"# Makefile for PuTTY under Visual C.\n".
"#\n# This file was created by `mkfiles.pl' from the `Recipe' file.\n".
"# DO NOT EDIT THIS FILE DIRECTLY; edit Recipe or mkfiles.pl instead.\n";
print $help;
print
"\n".
"# If you rename this file to `Makefile', you should change this line,\n".
"# so that the .rsp files still depend on the correct makefile.\n".
"MAKEFILE = Makefile.vc\n".
"\n".
"# C compilation flags\n".
"CFLAGS = /nologo /W3 /O1 /D_WINDOWS /D_WIN32_WINDOWS=0x401 /DWINVER=0x401\n".
"LFLAGS = /incremental:no /fixed\n".
"\n".
".c.obj:\n".
"\tcl \$(COMPAT) \$(FWHACK) \$(XFLAGS) \$(CFLAGS) /c \$*.c\n".
".rc.res:\n".
"\trc \$(FWHACK) \$(RCFL) -r -DWIN32 -D_WIN32 -DWINVER=0x0400 \$*.rc\n".
"\n";
print &splitline("all:" . join "", map { " $_.exe" } &progrealnames("GC"));
print "\n\n";
foreach $p (&prognames("GC")) {
  ($prog, $type) = split ",", $p;
  $objstr = &objects($p, "X.obj", "X.res", undef);
  print &splitline("$prog.exe: " . $objstr . " $prog.rsp"), "\n";
  print "\tlink \$(LFLAGS) -out:$prog.exe -map:$prog.map \@$prog.rsp\n\n";
}
foreach $p (&prognames("GC")) {
  ($prog, $type) = split ",", $p;
  print $prog, ".rsp: \$(MAKEFILE)\n";
  $objstr = &objects($p, "X.obj", "X.res", "X.lib");
  @objlist = split " ", $objstr;
  @objlines = ("");
  foreach $i (@objlist) {
    if (length($objlines[$#objlines] . " $i") > 50) {
      push @objlines, "";
    }
    $objlines[$#objlines] .= " $i";
  }
  $subsys = ($type eq "G") ? "windows" : "console";
  print "\techo /nologo /subsystem:$subsys > $prog.rsp\n";
  for ($i=0; $i<=$#objlines; $i++) {
    print "\techo$objlines[$i] >> $prog.rsp\n";
  }
  print "\n";
}
foreach $d (&deps("X.obj", "X.res", "", "\\")) {
  print &splitline(sprintf("%s: %s", $d->{obj}, join " ", @{$d->{deps}})),
      "\n";
}
print
"\n".
"# Hack to force version.o to be rebuilt always\n".
"version.obj: *.c *.h *.rc\n".
"\tcl \$(FWHACK) \$(VER) \$(CFLAGS) /c version.c\n\n".
"clean: tidy\n".
"\t-del *.exe\n\n".
"tidy:\n".
"\t-del *.obj\n".
"\t-del *.res\n".
"\t-del *.pch\n".
"\t-del *.aps\n".
"\t-del *.ilk\n".
"\t-del *.pdb\n".
"\t-del *.rsp\n".
"\t-del *.dsp\n".
"\t-del *.dsw\n".
"\t-del *.ncb\n".
"\t-del *.opt\n".
"\t-del *.plg\n".
"\t-del *.map\n".
"\t-del *.idb\n".
"\t-del debug.log\n";
select STDOUT; close OUT;

##-- MSVC 6 Workspace and projects
#
# Note: All files created in this section are written in binary
# mode, because although MSVC's command-line make can deal with
# LF-only line endings, MSVC project files really _need_ to be
# CRLF. Hence, in order for mkfiles.pl to generate usable project
# files even when run from Unix, I make sure all files are binary
# and explicitly write the CRLFs.
#
# Create directories if necessary
mkdir 'MSVC'
	if(! -d 'MSVC');
chdir 'MSVC';
@deps = &deps("X.obj", "X.res", "", "\\");
%all_object_deps = map {$_->{obj} => $_->{deps}} @deps;
# Create the project files
# Get names of all Windows projects (GUI and console)
my @prognames = &prognames("GC");
foreach $progname (@prognames) {
	create_project(\%all_object_deps, $progname);
}
# Create the workspace file
open OUT, ">putty.dsw"; binmode OUT; select OUT;
print
"Microsoft Developer Studio Workspace File, Format Version 6.00\r\n".
"# WARNING: DO NOT EDIT OR DELETE THIS WORKSPACE FILE!\r\n".
"\r\n".
"###############################################################################\r\n".
"\r\n";
# List projects
foreach $progname (@prognames) {
  ($windows_project, $type) = split ",", $progname;
	print "Project: \"$windows_project\"=\".\\$windows_project\\$windows_project.dsp\" - Package Owner=<4>\r\n";
}
print
"\r\n".
"Package=<5>\r\n".
"{{{\r\n".
"}}}\r\n".
"\r\n".
"Package=<4>\r\n".
"{{{\r\n".
"}}}\r\n".
"\r\n".
"###############################################################################\r\n".
"\r\n".
"Global:\r\n".
"\r\n".
"Package=<5>\r\n".
"{{{\r\n".
"}}}\r\n".
"\r\n".
"Package=<3>\r\n".
"{{{\r\n".
"}}}\r\n".
"\r\n".
"###############################################################################\r\n".
"\r\n";
select STDOUT; close OUT;
chdir '..';

sub create_project {
	my ($all_object_deps, $progname) = @_;
	# Construct program's dependency info
	%seen_objects = ();
	%lib_files = ();
	%source_files = ();
	%header_files = ();
	%resource_files = ();
	@object_files = split " ", &objects($progname, "X.obj", "X.res", "X.lib");
	foreach $object_file (@object_files) {
		next if defined $seen_objects{$object_file};
		$seen_objects{$object_file} = 1;
		if($object_file =~ /\.lib$/io) {
			$lib_files{$object_file} = 1;
			next;
		}
		$object_deps = $all_object_deps{$object_file};
		foreach $object_dep (@$object_deps) {
			if($object_dep =~ /\.c$/io) {
				$source_files{$object_dep} = 1;
				next;
			}
			if($object_dep =~ /\.h$/io) {
				$header_files{$object_dep} = 1;
				next;
			}
			if($object_dep =~ /\.(rc|ico)$/io) {
				$resource_files{$object_dep} = 1;
				next;
			}
		}
	}
	$libs = join " ", sort keys %lib_files;
	@source_files = sort keys %source_files;
	@header_files = sort keys %header_files;
	@resources = sort keys %resource_files;
  ($windows_project, $type) = split ",", $progname;
	mkdir $windows_project
		if(! -d $windows_project);
	chdir $windows_project;
  $subsys = ($type eq "G") ? "windows" : "console";
	open OUT, ">$windows_project.dsp"; binmode OUT; select OUT;
	print
	"# Microsoft Developer Studio Project File - Name=\"$windows_project\" - Package Owner=<4>\r\n".
	"# Microsoft Developer Studio Generated Build File, Format Version 6.00\r\n".
	"# ** DO NOT EDIT **\r\n".
	"\r\n".
	"# TARGTYPE \"Win32 (x86) Application\" 0x0101\r\n".
	"\r\n".
	"CFG=$windows_project - Win32 Debug\r\n".
	"!MESSAGE This is not a valid makefile. To build this project using NMAKE,\r\n".
	"!MESSAGE use the Export Makefile command and run\r\n".
	"!MESSAGE \r\n".
	"!MESSAGE NMAKE /f \"$windows_project.mak\".\r\n".
	"!MESSAGE \r\n".
	"!MESSAGE You can specify a configuration when running NMAKE\r\n".
	"!MESSAGE by defining the macro CFG on the command line. For example:\r\n".
	"!MESSAGE \r\n".
	"!MESSAGE NMAKE /f \"$windows_project.mak\" CFG=\"$windows_project - Win32 Debug\"\r\n".
	"!MESSAGE \r\n".
	"!MESSAGE Possible choices for configuration are:\r\n".
	"!MESSAGE \r\n".
	"!MESSAGE \"$windows_project - Win32 Release\" (based on \"Win32 (x86) Application\")\r\n".
	"!MESSAGE \"$windows_project - Win32 Debug\" (based on \"Win32 (x86) Application\")\r\n".
	"!MESSAGE \r\n".
	"\r\n".
	"# Begin Project\r\n".
	"# PROP AllowPerConfigDependencies 0\r\n".
	"# PROP Scc_ProjName \"\"\r\n".
	"# PROP Scc_LocalPath \"\"\r\n".
	"CPP=cl.exe\r\n".
	"MTL=midl.exe\r\n".
	"RSC=rc.exe\r\n".
	"\r\n".
	"!IF  \"\$(CFG)\" == \"$windows_project - Win32 Release\"\r\n".
	"\r\n".
	"# PROP BASE Use_MFC 0\r\n".
	"# PROP BASE Use_Debug_Libraries 0\r\n".
	"# PROP BASE Output_Dir \"Release\"\r\n".
	"# PROP BASE Intermediate_Dir \"Release\"\r\n".
	"# PROP BASE Target_Dir \"\"\r\n".
	"# PROP Use_MFC 0\r\n".
	"# PROP Use_Debug_Libraries 0\r\n".
	"# PROP Output_Dir \"Release\"\r\n".
	"# PROP Intermediate_Dir \"Release\"\r\n".
	"# PROP Ignore_Export_Lib 0\r\n".
	"# PROP Target_Dir \"\"\r\n".
	"# ADD BASE CPP /nologo /W3 /GX /O2 /D \"WIN32\" /D \"NDEBUG\" /D \"_WINDOWS\" /D \"_MBCS\" /YX /FD /c\r\n".
	"# ADD CPP /nologo /W3 /GX /O2 /D \"WIN32\" /D \"NDEBUG\" /D \"_WINDOWS\" /D \"_MBCS\" /YX /FD /c\r\n".
	"# ADD BASE MTL /nologo /D \"NDEBUG\" /mktyplib203 /win32\r\n".
	"# ADD MTL /nologo /D \"NDEBUG\" /mktyplib203 /win32\r\n".
	"# ADD BASE RSC /l 0x809 /d \"NDEBUG\"\r\n".
	"# ADD RSC /l 0x809 /d \"NDEBUG\"\r\n".
	"BSC32=bscmake.exe\r\n".
	"# ADD BASE BSC32 /nologo\r\n".
	"# ADD BSC32 /nologo\r\n".
	"LINK32=link.exe\r\n".
	"# ADD BASE LINK32 kernel32.lib user32.lib gdi32.lib winspool.lib comdlg32.lib advapi32.lib shell32.lib ole32.lib oleaut32.lib uuid.lib odbc32.lib odbccp32.lib /nologo /subsystem:$subsys /machine:I386\r\n".
	"# ADD LINK32 $libs /nologo /subsystem:$subsys /machine:I386\r\n".
	"# SUBTRACT LINK32 /pdb:none\r\n".
	"\r\n".
	"!ELSEIF  \"\$(CFG)\" == \"$windows_project - Win32 Debug\"\r\n".
	"\r\n".
	"# PROP BASE Use_MFC 0\r\n".
	"# PROP BASE Use_Debug_Libraries 1\r\n".
	"# PROP BASE Output_Dir \"Debug\"\r\n".
	"# PROP BASE Intermediate_Dir \"Debug\"\r\n".
	"# PROP BASE Target_Dir \"\"\r\n".
	"# PROP Use_MFC 0\r\n".
	"# PROP Use_Debug_Libraries 1\r\n".
	"# PROP Output_Dir \"Debug\"\r\n".
	"# PROP Intermediate_Dir \"Debug\"\r\n".
	"# PROP Ignore_Export_Lib 0\r\n".
	"# PROP Target_Dir \"\"\r\n".
	"# ADD BASE CPP /nologo /W3 /Gm /GX /ZI /Od /D \"WIN32\" /D \"_DEBUG\" /D \"_WINDOWS\" /D \"_MBCS\" /YX /FD /GZ /c\r\n".
	"# ADD CPP /nologo /W3 /Gm /GX /ZI /Od /D \"WIN32\" /D \"_DEBUG\" /D \"_WINDOWS\" /D \"_MBCS\" /YX /FD /GZ /c\r\n".
	"# ADD BASE MTL /nologo /D \"_DEBUG\" /mktyplib203 /win32\r\n".
	"# ADD MTL /nologo /D \"_DEBUG\" /mktyplib203 /win32\r\n".
	"# ADD BASE RSC /l 0x809 /d \"_DEBUG\"\r\n".
	"# ADD RSC /l 0x809 /d \"_DEBUG\"\r\n".
	"BSC32=bscmake.exe\r\n".
	"# ADD BASE BSC32 /nologo\r\n".
	"# ADD BSC32 /nologo\r\n".
	"LINK32=link.exe\r\n".
	"# ADD BASE LINK32 kernel32.lib user32.lib gdi32.lib winspool.lib comdlg32.lib advapi32.lib shell32.lib ole32.lib oleaut32.lib uuid.lib odbc32.lib odbccp32.lib /nologo /subsystem:$subsys /debug /machine:I386 /pdbtype:sept\r\n".
	"# ADD LINK32 $libs /nologo /subsystem:$subsys /debug /machine:I386 /pdbtype:sept\r\n".
	"# SUBTRACT LINK32 /pdb:none\r\n".
	"\r\n".
	"!ENDIF \r\n".
	"\r\n".
	"# Begin Target\r\n".
	"\r\n".
	"# Name \"$windows_project - Win32 Release\"\r\n".
	"# Name \"$windows_project - Win32 Debug\"\r\n".
	"# Begin Group \"Source Files\"\r\n".
	"\r\n".
	"# PROP Default_Filter \"cpp;c;cxx;rc;def;r;odl;idl;hpj;bat\"\r\n";
	foreach $source_file (@source_files) {
		print
		"# Begin Source File\r\n".
		"\r\n".
		"SOURCE=..\\..\\$source_file\r\n";
		if($source_file =~ /ssh\.c/io) {
			# Disable 'Edit and continue' as Visual Studio can't handle the macros
			print
			"\r\n".
			"!IF  \"\$(CFG)\" == \"$windows_project - Win32 Release\"\r\n".
			"\r\n".
			"!ELSEIF  \"\$(CFG)\" == \"$windows_project - Win32 Debug\"\r\n".
			"\r\n".
			"# ADD CPP /Zi\r\n".
			"\r\n".
			"!ENDIF \r\n".
			"\r\n";
		}
		print "# End Source File\r\n";
	}
	print
	"# End Group\r\n".
	"# Begin Group \"Header Files\"\r\n".
	"\r\n".
	"# PROP Default_Filter \"h;hpp;hxx;hm;inl\"\r\n";
	foreach $header_file (@header_files) {
		print
		"# Begin Source File\r\n".
		"\r\n".
		"SOURCE=..\\..\\$header_file\r\n".
		"# End Source File\r\n";
		}
	print
	"# End Group\r\n".
	"# Begin Group \"Resource Files\"\r\n".
	"\r\n".
	"# PROP Default_Filter \"ico;cur;bmp;dlg;rc2;rct;bin;rgs;gif;jpg;jpeg;jpe\"\r\n";
	foreach $resource_file (@resources) {
		print
		"# Begin Source File\r\n".
		"\r\n".
		"SOURCE=..\\..\\$resource_file\r\n".
		"# End Source File\r\n";
		}
	print
	"# End Group\r\n".
	"# End Target\r\n".
	"# End Project\r\n";
	select STDOUT; close OUT;
	chdir '..';
	}

##-- X/GTK/Unix makefile
open OUT, ">unix/Makefile.gtk"; select OUT;
print
"# Makefile for PuTTY under X/GTK and Unix.\n".
"#\n# This file was created by `mkfiles.pl' from the `Recipe' file.\n".
"# DO NOT EDIT THIS FILE DIRECTLY; edit Recipe or mkfiles.pl instead.\n";
# gcc command line option is -D not /D
($_ = $help) =~ s/=\/D/=-D/gs;
print $_;
print
"\n".
"# You can define this path to point at your tools if you need to\n".
"# TOOLPATH = /opt/gcc/bin\n".
"CC = \$(TOOLPATH)cc\n".
"\n".
&splitline("CFLAGS = -O2 -Wall -Werror -g -I. -I.. -I../charset `gtk-config --cflags`")."\n".
"XLDFLAGS = `gtk-config --libs`\n".
"ULDFLAGS =#\n".
"INSTALL=install\n",
"INSTALL_PROGRAM=\$(INSTALL)\n",
"INSTALL_DATA=\$(INSTALL)\n",
"prefix=/usr/local\n",
"exec_prefix=\$(prefix)\n",
"bindir=\$(exec_prefix)/bin\n",
"mandir=\$(prefix)/man\n",
"man1dir=\$(mandir)/man1\n",
"\n".
".SUFFIXES:\n".
"\n".
"%.o:\n".
"\t\$(CC) \$(COMPAT) \$(FWHACK) \$(XFLAGS) \$(CFLAGS) -c \$<\n".
"\n";
print &splitline("all:" . join "", map { " $_" } &progrealnames("XU"));
print "\n\n";
foreach $p (&prognames("XU")) {
  ($prog, $type) = split ",", $p;
  $objstr = &objects($p, "X.o", undef, undef);
  print &splitline($prog . ": " . $objstr), "\n";
  $libstr = &objects($p, undef, undef, "-lX");
  print &splitline("\t\$(CC)" . $mw . " \$(${type}LDFLAGS) -o \$@ " .
                   $objstr . " $libstr", 69), "\n\n";
}
foreach $d (&deps("X.o", undef, "../", "/")) {
  print &splitline(sprintf("%s: %s", $d->{obj}, join " ", @{$d->{deps}})),
      "\n";
}
print
"\n".
"version.o: FORCE;\n".
"# Hack to force version.o to be rebuilt always\n".
"FORCE:\n".
"\t\$(CC) \$(COMPAT) \$(FWHACK) \$(XFLAGS) \$(CFLAGS) \$(VER) -c ../version.c\n".
"clean:\n".
"\trm -f *.o". (join "", map { " $_" } &progrealnames("XU")) . "\n".
"\n",
"install:\n",
map("\t\$(INSTALL_PROGRAM) -m 755 $_ \$(DESTDIR)\$(bindir)/$_\n", &progrealnames("XU")),
map("\t\$(INSTALL_DATA) -m 644 $_ \$(DESTDIR)\$(man1dir)/$_\n", &manpages("XU", "1")),
"\n",
"install-strip:\n",
"\t\$(MAKE) install INSTALL_PROGRAM=\"\$(INSTALL_PROGRAM) -s\"\n",
"\n";
select STDOUT; close OUT;

##-- MPW Makefile
open OUT, ">mac/Makefile.mpw"; select OUT;
print <<END;
# Makefile for PuTTY under MPW.
#
# This file was created by `mkfiles.pl' from the `Recipe' file.
# DO NOT EDIT THIS FILE DIRECTLY; edit Recipe or mkfiles.pl instead.
END
# MPW command line option is -d not /D
($_ = $help) =~ s/=\/D/=-d /gs;
print $_;
print <<END;

ROptions     = `Echo "{VER}" | StreamEdit -e "1,\$ replace /=(\xc5)\xa81\xb0/ 'STR=\xb6\xb6\xb6\xb6\xb6"' \xa81 '\xb6\xb6\xb6\xb6\xb6"'"`

C_68K = {C}
C_CFM68K = {C}
C_PPC = {PPCC}
C_Carbon = {PPCC}

# -w 35 disables "unused parameter" warnings
COptions     = -i : -i :: -i ::charset -w 35 -w err -proto strict -ansi on \xb6
	       -notOnce
COptions_68K = {COptions} -model far -opt time
# Enabling "-opt space" for CFM-68K gives me undefined references to
# _\$LDIVT and _\$LMODT.
COptions_CFM68K = {COptions} -model cfmSeg -opt time
COptions_PPC = {COptions} -opt size -traceback
COptions_Carbon = {COptions} -opt size -traceback -d TARGET_API_MAC_CARBON

Link_68K = ILink
Link_CFM68K = ILink
Link_PPC = PPCLink
Link_Carbon = PPCLink

LinkOptions = -c 'pTTY'
LinkOptions_68K = {LinkOptions} -br 68k -model far -compact
LinkOptions_CFM68K = {LinkOptions} -br 020 -model cfmseg -compact
LinkOptions_PPC = {LinkOptions}
LinkOptions_Carbon = -m __appstart -w {LinkOptions}

Libs_68K =	"{CLibraries}StdCLib.far.o" \xb6
		"{Libraries}MacRuntime.o" \xb6
		"{Libraries}MathLib.far.o" \xb6
		"{Libraries}IntEnv.far.o" \xb6
		"{Libraries}Interface.o" \xb6
		"{Libraries}Navigation.far.o" \xb6
		"{Libraries}OpenTransport.o" \xb6
		"{Libraries}OpenTransportApp.o" \xb6
		"{Libraries}OpenTptInet.o" \xb6
		"{Libraries}UnicodeConverterLib.far.o"

Libs_CFM =	"{SharedLibraries}InterfaceLib" \xb6
		"{SharedLibraries}StdCLib" \xb6
		"{SharedLibraries}AppearanceLib" \xb6
			-weaklib AppearanceLib \xb6
		"{SharedLibraries}NavigationLib" \xb6
			-weaklib NavigationLib \xb6
		"{SharedLibraries}TextCommon" \xb6
			-weaklib TextCommon \xb6
		"{SharedLibraries}UnicodeConverter" \xb6
			-weaklib UnicodeConverter

Libs_CFM68K =	{Libs_CFM} \xb6
		"{CFM68KLibraries}NuMacRuntime.o"

Libs_PPC =	{Libs_CFM} \xb6
		"{SharedLibraries}ControlsLib" \xb6
			-weaklib ControlsLib \xb6
		"{SharedLibraries}WindowsLib" \xb6
			-weaklib WindowsLib \xb6
		"{SharedLibraries}OpenTransportLib" \xb6
			-weaklib OTClientLib \xb6
			-weaklib OTClientUtilLib \xb6
		"{SharedLibraries}OpenTptInternetLib" \xb6
			-weaklib OTInetClientLib \xb6
		"{PPCLibraries}StdCRuntime.o" \xb6
		"{PPCLibraries}PPCCRuntime.o" \xb6
		"{PPCLibraries}CarbonAccessors.o" \xb6
		"{PPCLibraries}OpenTransportAppPPC.o" \xb6
		"{PPCLibraries}OpenTptInetPPC.o"

Libs_Carbon =	"{PPCLibraries}CarbonStdCLib.o" \xb6
		"{PPCLibraries}StdCRuntime.o" \xb6
		"{PPCLibraries}PPCCRuntime.o" \xb6
		"{SharedLibraries}CarbonLib" \xb6
		"{SharedLibraries}StdCLib"

END
print &splitline("all \xc4 " . join(" ", &progrealnames("M")), undef, "\xb6");
print "\n\n";
foreach $p (&prognames("M")) {
  ($prog, $type) = split ",", $p;

  print &splitline("$prog \xc4 $prog.68k $prog.ppc $prog.carbon",
		   undef, "\xb6"), "\n\n";

  $rsrc = &objects($p, "", "X.rsrc", undef);

  foreach $arch (qw(68K CFM68K PPC Carbon)) {
      $objstr = &objects($p, "X.\L$arch\E.o", "", undef);
      print &splitline("$prog.\L$arch\E \xc4 $objstr $rsrc", undef, "\xb6");
      print "\n";
      print &splitline("\tDuplicate -y $rsrc {Targ}", 69, "\xb6"), "\n";
      print &splitline("\t{Link_$arch} -o {Targ} -fragname $prog " .
		       "{LinkOptions_$arch} " .
		       $objstr . " {Libs_$arch}", 69, "\xb6"), "\n";
      print &splitline("\tSetFile -a BMi {Targ}", 69, "\xb6"), "\n\n";
  }

}
foreach $d (&deps("", "X.rsrc", "::", ":")) {
  next unless $d->{obj};
  print &splitline(sprintf("%s \xc4 %s", $d->{obj}, join " ", @{$d->{deps}}),
		   undef, "\xb6"), "\n";
  print "\tRez ", $d->{deps}->[0], " -o {Targ} {ROptions}\n\n";
}
foreach $arch (qw(68K CFM68K)) {
    foreach $d (&deps("X.\L$arch\E.o", "", "::", ":")) {
	 next unless $d->{obj};
	print &splitline(sprintf("%s \xc4 %s", $d->{obj},
				 join " ", @{$d->{deps}}),
			 undef, "\xb6"), "\n";
	 print "\t{C_$arch} ", $d->{deps}->[0],
	       " -o {Targ} {COptions_$arch}\n\n";
     }
}
foreach $arch (qw(PPC Carbon)) {
    foreach $d (&deps("X.\L$arch\E.o", "", "::", ":")) {
	 next unless $d->{obj};
	print &splitline(sprintf("%s \xc4 %s", $d->{obj},
				 join " ", @{$d->{deps}}),
			 undef, "\xb6"), "\n";
	 # The odd stuff here seems to stop afpd getting confused.
	 print "\techo -n > {Targ}\n";
	 print "\tsetfile -t XCOF {Targ}\n";
	 print "\t{C_$arch} ", $d->{deps}->[0],
	       " -o {Targ} {COptions_$arch}\n\n";
     }
}
select STDOUT; close OUT;

##-- lcc makefile
open OUT, ">Makefile.lcc"; select OUT;
print
"# Makefile for PuTTY under lcc.\n".
"#\n# This file was created by `mkfiles.pl' from the `Recipe' file.\n".
"# DO NOT EDIT THIS FILE DIRECTLY; edit Recipe or mkfiles.pl instead.\n";
# lcc command line option is -D not /D
($_ = $help) =~ s/=\/D/=-D/gs;
print $_;
print
"\n".
"# If you rename this file to `Makefile', you should change this line,\n".
"# so that the .rsp files still depend on the correct makefile.\n".
"MAKEFILE = Makefile.lcc\n".
"\n".
"# C compilation flags\n".
"CFLAGS = -D_WINDOWS\n".
"\n".
"# Get include directory for resource compiler\n".
"\n".
".c.obj:\n".
&splitline("\tlcc -O -p6 \$(COMPAT) \$(FWHACK)".
  " \$(XFLAGS) \$(CFLAGS)  \$*.c",69)."\n".
".rc.res:\n".
&splitline("\tlrc \$(FWHACK) \$(RCFL) -r \$*.rc",69)."\n".
"\n";
print &splitline("all:" . join "", map { " $_.exe" } &progrealnames("GC"));
print "\n\n";
foreach $p (&prognames("GC")) {
  ($prog, $type) = split ",", $p;
  $objstr = &objects($p, "X.obj", "X.res", undef);
  print &splitline("$prog.exe: " . $objstr ), "\n";
  $subsystemtype = undef;
  if ($prog eq "pageant" || $prog eq "putty" ||$prog eq "puttygen" || $prog eq "puttytel") { 
	$subsystemtype = "-subsystem  windows";	}
  my $libss = "shell32.lib wsock32.lib ws2_32.lib winspool.lib winmm.lib imm32.lib";
  print &splitline("\tlcclnk $subsystemtype -o $prog.exe $objstr $libss");
  print "\n\n";
}


foreach $d (&deps("X.obj", "X.res", "", "\\")) {
  print &splitline(sprintf("%s: %s", $d->{obj}, join " ", @{$d->{deps}})),
    "\n";
}
print
"\n".
"version.o: FORCE\n".
"# Hack to force version.o to be rebuilt always\n".
"FORCE:\n".
"\tlcc \$(FWHACK) \$(VER) \$(CFLAGS) /c version.c\n\n".
"clean:\n".
"\t-del *.obj\n".
"\t-del *.exe\n".
"\t-del *.res\n";

select STDOUT; close OUT;

