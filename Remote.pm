
####################################################################
# $Id: Remote.pm,v 1.10 2000/04/17 19:48:07 nwiger Exp $
#
# Copyright (c) 1999-2000 Nathan Wiger (nate@wiger.org)
#
# This module takes care of dealing with files regardless of whether
# they're local or remote. It allows you to create and edit files
# without having to worry about their physical location. If a file
# passed in is of the form 'host:/path/to/file', then it uses rsh/rcp
# or ssh/scp (depending on how you configure it) calls to edit the file
# remotely. Otherwise, it edits the file locally.
#
# It is my intent to provide a full set of File::Remote routines that
# mirror the standard file routines. If anybody notices any that are
# missing or even has some suggestions for useful ones, I'm all ears.
#
# For full documentation, try "/__END__" or "man File::Remote"
#
# This module is free software; you may copy this under the terms of
# the GNU General Public License, or the Artistic License, copies of
# which should have accompanied your Perl kit.
#
####################################################################

#=========================== Setup =================================

# Basic module setup
require 5.003;
package File::Remote;
use Exporter;
@ISA = qw(Exporter);

@EXPORT_OK   = qw(rreadfile rwritefile rmkdir rrmdir rrm runlink rcp rcopy rtouch rchown
		  rchmod rmove rmv rbackup setrsh setrcp settmp ropen rclose rappend rprepend
		  readfile writefile mkdir rmdir rm unlink cp copy touch chown
		  chmod move mv backup open close append prepend);

%EXPORT_TAGS = ('files' => [qw(ropen rclose rreadfile rwritefile runlink rcopy rtouch rmove
			       rbackup rappend rprepend)],
		'config'=> [qw(setrsh setrcp settmp)],
                'dirs'  => [qw(rmkdir rrmdir)],
                'perms' => [qw(rchown rchmod)],
                'standard' => [qw(ropen rclose rreadfile rwritefile runlink rcopy rtouch rmove
				  rbackup rappend rprepend setrsh setrcp settmp rmkdir rrmdir
				  rchown rchmod)],
                'aliases'  => [qw(rrm rmv rcp)],
		'replace' => [qw(open close readfile writefile unlink rm copy cp touch move mv
				 backup append prepend setrsh setrcp settmp mkdir rmdir chown chmod)]
		);

# Straight from CPAN
$VERSION = do { my @r=(q$Revision: 1.10 $=~/\d+/g); sprintf "%d."."%02d"x$#r,@r }; 

# Errors
use Carp;

# Need the basic File classes to make it work
use File::Copy qw(!copy !move);		# prevent namespace clashes
use File::Path;

# For determining remote or local file
use Sys::Hostname;

#======================== Configuration ==========================

# Defaults
$RSH = "/usr/bin/rsh";
$RCP = "/usr/bin/rcp";
$TMP = "/tmp";

# This determines whether or not we should spend some time trying
# to see if rsh and rcp are set to valid values before using them.
# By default these checks are not done because they're SLOW...
# Note that if you enable these then you must use absolute paths
# when calling setrsh and setrcp; "setrsh('ssh')" will fail.
$CHECK_RSH_IS_VALID = 0;
$CHECK_RCP_IS_VALID = 0;

# This is whether or not to spend the extra cycles (and network
# latency) checking whether a remote file is actually writeable
# when we try to open it with > or >>. Note: Unsetting this can
# result in strange and unpredictable behavior, messing with it
# it NOT recommended.
$CHECK_REMOTE_FILES = 1;

#======================== Misc. Settings =========================

# This is the default class for the File::Remote object (from CGI.pm!)
$DefaultClass ||= 'File::Remote';

# This should not need to be overridden
($hostname = hostname()) =~ s/\..*//;

# Need to check our OS. As of this release, only UNIX is supported;
# perhaps this will change in the future, but probably not.
# Don't check $^O because we'd have to write an exhaustive function.
die "Sorry, File::Remote only supports UNIX systems\n" unless (-d "/");

#========================== Functions ============================

#------------------------------------------------
# "Constructor" function to handle defaults
#------------------------------------------------

#######
# Usage: $remote = new File::Remote;
#
# This constructs a new File::Remote object
#######

sub new {
   # Easy mostly-std new()
   my $self = shift;
   my $class = ref($self) || $self || $DefaultClass;
   return bless {
       'RSH' => $File::Remote::RSH,
       'RCP' => $File::Remote::RCP,
       'TMP' => $File::Remote::TMP
   }, $class;
}

#------------------------------------------------
# Private Functions (for public see "/__DATA__")
#------------------------------------------------

#######
# Usage: my($self, @args) = _self_or_default(@_);
#
# This is completely stolen from the amazing CGI.pm. I did 
# not write this!! Thanks, Lincoln Stein! :-)
#######

sub _self_or_default {

   return @_ if defined($_[0]) && (!ref($_[0])) && ($_[0] eq 'File::Remote');
   unless (defined($_[0]) && (ref($_[0]) eq 'File::Remote' || UNIVERSAL::isa($_[0],'File::Remote'))) {
      $Q = $File::Remote::DefaultClass->new unless defined($Q);
      unshift(@_, $Q);
   }
   return @_;
}

#######
# Usage: $tmpfile = $remote->_tmpfile($file);
#
# This sets a unique temp file for each $self/$file combo,
# which is used during remote rsh/rcp calls
#######

sub _tmpfile {

   my($self, $file) = _self_or_default(@_);
   $file =~ tr#[:/]#_#;		# "fix" filename
   my($tmpdir, $tmpfile);
   $tmpdir = $self->settmp;

   # Have a little loop so that we don't collide w/ other File::Remote's
   my $num = $$;
   do {
      $tmpfile = "$tmpdir/.rfile.$file.$num";
      $num++;
   } while (-f $tmpfile);
   return $tmpfile;
}

#######
# Usage: $remote->_system(@cmd) or return undef;
#
# Front-end for built-in firing off system commands to twiddle
# return vals. Here, we don't actually use system() because we
# need the appropriate return value so that $! makes sense.
#######

sub _system {
   my($self, @cmd) = _self_or_default(@_);
   chomp($return = `@cmd 2>&1 1>/dev/null || echo 32`);	# return "Broken pipe" if cmd invalid
   if ($return) {
      # if echo'ed an int (internal tests), use it, else use "Permission denied" (13)
      $return =~ m/^(\d+)$/;
      $! = $1 || 13;
      return undef;
   }
   return 1;
}

####### 
# Usage: my($host, $file) = _parsepath($path);
#
# This is used to parse the $path param to look for host:/file
# This always returns an array, the deal is that if the file
# is remote, you get a host (arg1). Otherwise, it's undef.
#######

sub _parsepath {

   my($self, $file) = _self_or_default(@_);
   my($rhost, $rfile) = split ':', $file;

   return(undef, $rhost) unless $rfile; # return the file if no colon (faster)
   if($hostname =~ /^$rhost\.?.*/) {
      return(undef, $rfile); # file is actually local
   }
   return($rhost, $rfile); # file is remote after all
}
 
#######
# Usage: $fh = _to_filehandle($thingy);
#
# This is so we can pass in a filehandle or typeglob to open(),
# and close(). The majority of it is from Licoln Stein's CGI.pm
# but there's a change to grab an implicit "main::". We also
# don't check for fileno, since these are probably NOT open yet.
#######

sub _to_filehandle {

   my($self, $thingy) = _self_or_default(@_);

   return undef unless $thingy;
   return $thingy if UNIVERSAL::isa($thingy,'GLOB');
   return $thingy if UNIVERSAL::isa($thingy,'FileHandle');

   if (!ref($thingy)) {
      my $caller = 1;
      my $tmp = "main\:\:$thingy";	# assume main package
      while (my $package = caller($caller++)) {
         $tmp = $thingy =~ /[\':]/ ? $thingy : "$package\:\:$thingy";
         return $tmp if defined(fileno($tmp));
      }
      return $tmp;	# don't check fileno here
   }

   return undef;
}

#------------------------------------------------
# Public functions - all are exportable
#------------------------------------------------

# Everything down here should be SelfLoaded
# Can't use the SelfLoader because of conflicts with CORE::open
#__DATA__

#######
# Usage: $remote->setXXX($value);
#
# These three functions are for setting necessary variables.
# All of them do sanity checks which will be called both when
# a variable is assigned as well as retrieved. This prevents
# "mass badness". If not value is passed, the current setting
# is returned (good for checking).
#######

sub setrsh {
   # Sets the variable $self->{RSH}, which is what to use for rsh calls
   my($self, $value) = _self_or_default(@_);
   $self->{RSH} = $value if $value;

   # This check was removed because of relative paths/speed.
   if ($CHECK_RSH_IS_VALID) {
      croak "File::Remote::setrsh() set to non-executable file '$self->{RSH}'"
         unless (-x $self->{RSH});
   }

   return $self->{RSH};
}
   
sub setrcp {
   # Sets the variable $self->{RCP}, which is what to use for rcp calls
   my($self, $value) = _self_or_default(@_);
   $self->{RCP} = $value if $value;

   # This check was removed because of relative paths/speed.
   if ($CHECK_RCP_IS_VALID) {
      croak "File::Remote::setrcp() set to non-executable file '$self->{RCP}'"
         unless (-x $self->{RCP});
   }

   return $self->{RCP};
}

sub settmp {
   # Sets the variable $TMP, which refs the temp dir needed to hold
   # temporary files during rsh/rcp calls
   my($self, $value) = _self_or_default(@_);
   $self->{TMP} = $value if $value;
   croak "File::Remote::settmp() set to non-existent dir '$self->{TMP}'"
      unless (-d $self->{TMP});
   return $self->{TMP};
}


#######
# Usage: $remote->open(FILEHANDLE, $file);
#
# opens file onto FILEHANDLE (or typeglob) just like CORE::open()
#
# There's one extra step here, and that's creating a hash that
# lists the open filehandles and their corresponding filenames.
# If anyone knows a better way to do this, LET ME KNOW! This is
# a major kludge, but is needed in order to copy back the changes
# made to remote files via persistent filehandles.
#######

*ropen = \&open;
sub open {

   my($self, $handle, $file) = _self_or_default(@_);
   croak "Bad usage of File::Remote::open" unless ($handle && $file);

   # Private vars
   my($f, $fh, $tmpfile);

   # Before parsing path, need to check for <, >, etc
   $file =~ m/^([\<\>\|\+]*)\s*(.*)/;
   $file = $2;
   $method = $1 || '<';

   croak "Unsupported file method '$method'" unless ($method =~ m/^\+?[\<\>\|]{1,2}$/);
   my($rhost, $lfile) = _parsepath($file);

   # Catch for remote pipes
   if (($method =~ m/\|/) && $rhost) {
      croak "Sorry, File::Remote does not support writing to remote pipes" 
   }

   # Setup filehandle
   $fh = _to_filehandle($handle) or return undef;;

   # Check if it's open already - if so, close it first like native Perl
   if($File::Remote::open_handles{$fh}) {
      $self->close($handle) or return undef;
   }

   # Check for local or remote files
   if($rhost) {
      $tmpfile = $self->_tmpfile($file);
      $f = $tmpfile;

      # XXX Add this filehandle to our hash - this is a big kludge,
      # XXX if there's something I'm missing please let me know!!!
      # XXX This is so that on close(), the file can be copied back
      # XXX over to the source to overwrite whatever's there.
      # XXX Because of the performance hit, only add it if it's rw.
      if ($method =~ m/\>/) {

         # First check to see if the remote file is writeable,
         # but only if the variable $CHECK_REMOTE_FILES is on.
         # Do our checks thru test calls that echo $! codes if
         # they fail...

         if($File::Remote::CHECK_REMOTE_FILES) {
            my $dir;
            ($dir = $lfile) =~ s@(.*)/.*@$1@;
            $self->_system($self->setrsh, $rhost,
		"'if test -f $lfile; then
			test -w $lfile || echo 13 >&2;
		  else
			test -d $dir || echo 2 >&2;
		  fi'") or return undef;
         }

         $File::Remote::open_rw_remote_handles{$fh} = $file;
         $File::Remote::open_rw_remote_tmpfiles{$file} = $tmpfile;
      } else {
         # push tmpfile onto an array
         push @File::Remote::open_ro_remote_tmpfiles, $tmpfile;
      }

      # If we escaped that mess, copy our file over locally
      # For open(), ignore failed copies b/c the file might be new
      $self->copy($file, $tmpfile);

   } else {
      $f = $lfile;
   }

   # Add to our hash of open files when we've got it open
   $File::Remote::open_handles{$fh} = $file;

   # All we do is pass it straight thru to open()
   CORE::open($fh, "$method $f") or return undef;
   return 1;
}

#######
# Usage: $remote->open(FILEHANDLE, $file);
#
# closes FILEHANDLE and flushes buffer just like CORE::close()
#######

*rclose = \&close;
sub close {

   my($self, $handle) = _self_or_default(@_);
   croak "Bad usage of File::Remote::close" unless ($handle);
 
   # Private vars
   my($file, $fh, $tmpfile);

   # Setup filehandle and close
   $fh = _to_filehandle($handle) or return undef;
   CORE::close($fh) or return undef;

   # See if it's a writable remote handle
   if($file = $File::Remote::open_rw_remote_handles{$fh}) {

      # If it's a remote file, we have extra stuff todo. Basically,
      # we need to copy the local tmpfile over to the remote host
      # which has the equivalent effect of flushing buffers for
      # local files (as far as the user can tell).

      my($rhost, $lfile) = _parsepath($file);	
      if($rhost) {
         $tmpfile = $File::Remote::open_rw_remote_tmpfiles{$file};
         $self->copy($tmpfile, $file) or return undef;
         CORE::unlink($tmpfile);
         delete $File::Remote::open_rw_remote_handles{$fh};
         delete $File::Remote::open_rw_remote_tmpfiles{$file};
      }
   }
   return 1;
}

# This is a special method to close all open rw remote filehandles on exit
END {
   my($fh, $file);
   while(($fh, $file) = each(%File::Remote::open_remote_handles)) {
      carp "$fh remote filehandle left open, use File::Remote::close()" if ($^W);
      &close($fh);	# ignore errors, programmer should use close()
   }
   foreach $file (@File::Remote::open_ro_remote_tmpfiles) {
      CORE::unlink($file);
   }
}

#######
# Usage: $remote->touch($file);
#
# "touches" a file (creates an empty one or updates mod time)
#######

*rtouch = \&touch;
sub touch {
   my($self, $file) = _self_or_default(@_);
   croak "Bad usage of File::Remote::touch" unless ($file);
   my($rhost, $lfile) = _parsepath($file);
}


#######
# Usage: @file = $remote->readfile($file);
#
# This reads an entire file and returns it as an array. In a
# scalar context the number of lines will be returned.
#######

*rreadfile = \&readfile;
sub readfile {

   my($self, $file) = _self_or_default(@_);
   croak "Bad usage of File::Remote::readfile" unless ($file);
   my($rhost, $lfile) = _parsepath($file);

   # Private vars
   my($f, $fh, $tmpfile);

   # Check for local or remote files
   if($rhost) {
      $tmpfile = $self->_tmpfile($file);
      $self->copy($file, $tmpfile) or return undef;
      $f = $tmpfile;
   } else {
      $f = $lfile;
   }

   # These routines borrowed heavily from File::Slurp
   local(*F);
   CORE::open(F, "<$f") or return undef;
   my @r = <F>;
   CORE::close(F) or return undef;

   # Remove the local copy
   CORE::unlink($tmpfile);

   return @r if wantarray;
   #return join("", @r);
}

#######
# Usage: $remote->writefile($file, @file);
#
# This writes an entire file using the array passed in as
# the second arg. It overwrites any existing file of the
# same name. To back it up first, use backup().
#######

*rwritefile = \&writefile;
sub writefile {

   my($self, $file, @data) = _self_or_default(@_);
   croak "Bad usage of File::Remote::writefile" unless ($file);
   my($rhost, $lfile) = _parsepath($file);

   # Private vars
   my($f, $fh, $tmpfile);

   # Check for local or remote files
   if($rhost) {
      $tmpfile = $self->_tmpfile($file);
      $f = $tmpfile;
   } else {
      $f = $lfile;
   }
   
   # These routines borrowed heavily from File::Slurp
   local(*F);
   CORE::open(F, ">$f") or return undef;
   print F @data or return undef;
   CORE::close(F) or return undef;
 
   # Need to copy the file back over
   if($rhost) {
      if(-f $tmpfile) {
         $self->copy($tmpfile, $file) or return undef;
         CORE::unlink($tmpfile);  
      } else {
         carp "File::Remote Internal Error: Attempted to write to $file but $tmpfile missing!";
         return undef;
      }
   }

   return 1;
}

#######
# Usage: $remote->mkdir($dir, $mode);
#
# This creates a new dir with the specified octal mode.
#######

*rmkdir = \&mkdir;
sub mkdir {

   # Local dirs go to mkpath, remote to mkdir -p
   my($self, $dir, $mode) = _self_or_default(@_);
   croak "Bad usage of File::Remote::mkdir" unless ($dir);
   my($rhost, $ldir) = _parsepath($dir);
   #$mode = '0755' unless $mode;

   if($rhost) {
      $self->_system($self->setrsh, $rhost, "'mkdir -p $ldir'") or return undef;
   } else {
      mkpath(["$ldir"], 0, $mode) || return undef;
   }
   return 1;
}

#######
# Usage: $remote->rmdir($dir, $recurse);
#
# This removes the specified dir.
#######

*rrmdir = \&rmdir;
sub rmdir {

   my($self, $dir, $recurse) = _self_or_default(@_);
   croak "Bad usage of File::Remote::rmdir" unless ($dir);
   my($rhost, $ldir) = _parsepath($dir);
   $recurse = 1 unless defined($recurse);

   if($rhost) {
      if ($recurse) {
         $self->_system($self->setrsh, $rhost, "rm -rf $ldir") or return undef;
      } else {
         $self->_system($self->setrsh, $rhost, "rmdir $ldir") or return undef;
      }
   } else {
      if ($recurse) {
         rmtree(["$ldir"], 0, 0) or return undef;
      } else {
         rmdir $ldir or return undef;
      }
   }
   return 1;
}
 
#######
# Usage: $remote->copy($file1, $file2);
#
# This copies files around, just like UNIX cp. If one of
# the files is remote, it uses rcp. Both files cannot be
# remote.
#######

*rcp = \&copy;
*rcopy = \&copy;
*cp = \&copy;
sub copy {
   # This copies the given file, either locally or remotely
   # depending on whether or not it's remote or not.
   my($self, $srcfile, $destfile) = _self_or_default(@_);
   croak "Bad usage of File::Remote::copy" unless ($srcfile && $destfile);
   my($srhost, $slfile) = _parsepath($srcfile);
   my($drhost, $dlfile) = _parsepath($destfile);

   if($srhost || $drhost) {
      $self->_system($self->setrcp, $srcfile, $destfile) or return undef;
   } else {
      File::Copy::copy($slfile, $dlfile) or return undef;
   }
   return 1;
}

#######
# Usage: $remote->move($file1, $file2);
#
# This moves files around, just like UNIX mv. If one of
# the files is remote, it uses rcp/rm. Both files cannot be
# remote.
#######

*rmove = \&move;
*rmv = \&move;
*mv = \&move;
sub move {

   # This does NOT fall through to a standard rename command,
   # simply because there are too many platforms on which this
   # works too differently (Solaris vs. Linux, for ex).

   (&copy(@_) && &unlink(@_)) || return undef;
   return 1;
}

#######
# Usage: $remote->chown($file1, $file2);
#
# This chown's files just like UNIX chown.
#######


*rchown = \&chown;
sub chown {

   # If remote, subshell it; else, use Perl's chown
   # Form of chown is the same as normal chown
   my($self, $uid, $gid, $file) = _self_or_default(@_);
   croak "Bad usage of File::Remote::chown" unless ($uid && $gid && $file);
   my($rhost, $lfile) = _parsepath($file);

   if($rhost) {
      $self->_system($self->setrsh, $rhost, "'chown $uid $lfile ; chgrp $gid $lfile'") or return undef;
   } else {
      # Check if we need to resolve stuff
      ($uid) = getpwnam($uid) if ($uid =~ /[a-zA-Z]/);
      ($gid) = getgrnam($gid) if ($gid =~ /[a-zA-Z]/);
      chown($uid, $gid, $lfile) || return undef;
   }
   return 1;
}

#######
# Usage: $remote->chmod($mode, $file);
#
# This chmod's files just like UNIX chmod.
#######

*rchmod = \&chmod;
sub chmod {

   # Same as chown, really easy
   my($self, $mode, $file) = _self_or_default(@_);
   croak "Bad usage of File::Remote::chmod" unless ($mode && $file);
   my($rhost, $lfile) = _parsepath($file);

   if($rhost) {
      $self->_system($self->setrsh, $rhost, "'chmod $mode $lfile'") or return undef;
   } else {
      chmod($mode, $lfile) || return undef;
   }
   return 1;
}

#######
# Usage: $remote->unlink($file);
#
# This removes files, just like UNIX rm.
#######

*rrm = \&unlink;
*rm = \&unlink;
*runlink = \&unlink;
sub unlink {

   # Really easy
   my($self, $file) = _self_or_default(@_);
   croak "Bad usage of File::Remote::unlink" unless ($file);
   my($rhost, $lfile) = _parsepath($file);

   if($rhost) {
      $self->_system($self->setrsh, $rhost, "'rm -f $lfile'") or return undef;
   } else {
      CORE::unlink($lfile) || return undef;
   }
   return 1;
}

#######
# Usage: $remote->backup($file, $suffix|$filename);
#
# Remotely backs up a file. A little tricky, but not too much.
# If the file is remote we just do a 'rcp -p'. If it's local,
# we do a cp, along with some stat checks. The cool thing about
# this function is that it takes two arguments, the second
# can be either a suffix (like '.bkup') or a full file name
# (like '/local/backups/myfile'), and the function does the
# appropriate thing. If will also accept a 'host:/dir/file'
# arg as the suffix, which means you can do this:
# 
#   rbackup('mainhost:/dir/file', 'backuphost:/dir/new/file');
#######

*rbackup = \&backup;
sub backup {


   my($self, $file, $suffix) = _self_or_default(@_);
   croak "Bad usage of File::Remote::backup" unless ($file);
   $suffix ||= 'bkup';

   my($rhost, $lfile) = _parsepath($file);
   my($bhost, $bfile) = _parsepath($suffix);

   # See if the thing is a suffix or filename
   $bfile = "$file.$suffix" unless ($bfile =~ m@/@); # a path name

   # All we do now if drop thru to our own copy routine
   $self->copy($file, $bfile) or return undef;
   return 1;
}

#######
# Usage: $remote->append($file, @file);
#
# This is just like writefile, only that it appends to the file
# rather than overwriting it.
#######

*rappend = \&append;
sub append {
   my($self, $file, @file) = _self_or_default(@_);
   croak "Bad usage of File::Remote::append" unless ($file);
   my @prefile = $self->readfile($file) or return undef;
   my @newfile = (@prefile, @file) or return undef;
   $self->writefile($file, @newfile) or return undef;
   return 1;
}

#######
# Usage: $remote->prepend($file, @file);
#
# This is just like writefile, only that it prepends to the file
# rather than overwriting it.
#######

*rprepend = \&prepend;
sub prepend {
   my($self, $file, @file) = _self_or_default(@_);
   croak "Bad usage of File::Remote::prepend" unless ($file);
   my @postfile = $self->readfile($file) or return undef;
   my @newfile = (@file, @postfile) or return undef;
   $self->writefile($file, @newfile) or return undef;
   return 1;
}

1;

#------------------------------------------------
# Documentation starts down here...
#------------------------------------------------

__END__ DATA

=head1 NAME

File::Remote - Read/write/edit remote files transparently

=head1 SYNOPSIS

   #  
   # Two ways to use File::Remote
   # First, the object-oriented style
   #  
   use File::Remote;
   my $remote = new File::Remote;
   $remote->settmp('/var/tmp');		# custom tmp dir
 
   # Standard filehandles
   $remote->open(FILE, '>>host:/remote/file') or die "Open: $!\n";
   print FILE "Here's a line that's added.\n";
   $remote->close(FILE);
 
   # Create a new file and change its permissions
   $remote->mkdir('host:/remote/dir');
   $remote->touch('host:/remote/dir/file');
   $remote->chown('root', 'other', 'host:/remote/dir/file');
   $remote->chmod('0600', 'host:/remote/dir/file');
 
   # Move files around
   $remote->copy('/local/file', 'host:/remote/file') or warn "Copy: $!\n";
   $remote->move('host:/remote/file', '/local/file');
 
   # Read and write whole files
   my @file = $remote->readfile('host:/remote/file');
   $remote->writefile('/local/file', @file);
 
   # Backup a file with a suffix
   $remote->backup('host:/remote/oldfile', 'save');
 
   # Use secure methods
   my $secure = new File::Remote;
   $secure->setrsh('/local/bin/ssh');	# for secure
   $secure->setscp('/local/bin/scp');	# connections
 
   $secure->unlink('/local/file');
   $secure->rmdir('host:/remote/dir');
 
   #
   # Next, the function-based style. Here, we can use the 
   # special :replace tag to overload Perl builtins!
   #
   use File::Remote qw(:replace);	# special :replace tag

   open(REMOTE, 'host:/remote/file') or die "Open: $!\n";
   print while (<REMOTE>);
   close(REMOTE);

   open(LOCAL, '>>/local/file');	# still works!
   print LOCAL "This is a new line.\n";
   close(LOCAL); 
 
   mkdir('host:/remote/dir', 0755);
   unlink('host:/remote/file');
   unlink('/local/file');		# still works too!

=head1 DESCRIPTION

This module takes care of dealing with files regardless of whether
they're local or remote.  It allows you to create and edit files without
having to worry about their physical location on the network.  If a file
passed into a function is of the form 'host:/path/to/file', then
File::Remote uses rsh/rcp (or ssh/scp, depending on how you configure it)
to edit the file remotely.  Otherwise, it assumes the file is local and
passes calls directly through to Perl's core functions.

The nice thing about this module is that you can use it for I<all> your
file calls, since it handles both remote and local files transparently.
This means you don't have to put a whole bunch of checks for remote files
in your code.  Plus, if you use the function-oriented interface along with
the I<:replace> tag, you can actually redefine the Perl builtin file
functions so that your existing Perl scripts can automatically handle
remote files with no re-engineering!

There are two ways to program with File::Remote, an object-oriented
style and a function-oriented style.  Both methods work equally well,
it's just a matter of taste.  One advantage of the object-oriented
method is that this allows you to read and write from different servers
using different methods (eg, rsh vs. ssh) simultaneously:

   # Object-oriented method
   use File::Remote;
   my $remote = new File::Remote;
   my $secure = new File::Remote;
   $secure->setrsh('/local/bin/ssh');
   $secure->setrcp('/local/bin/scp');

   # Securely copy, write, and remove a file in one swoop...
   $remote->open(LOCAL, '/local/file') or die "Open failed: $!\n";
   $secure->open(REMOTE, 'host:/remote/file') or die "Open failed: $!\n";
   print REMOTE "$_" while (<LOCAL>);

   $remote->close(LOCAL);
   $secure->close(REMOTE);

   # And let's move some files around securely
   $secure->move('/local/file', 'host:/remote/file');
   $secure->copy('host:/remote/file', '/local/file');

Because the names for the File::Remote methods clash with the Perl builtins,
if you use the function-oriented style with the I<:standard> tag there is
an extra 'r' added to the front of the function names.  Thus, '$remote->open'
becomes 'ropen' in the function-oriented version:

   # Function-oriented method
   use File::Remote qw(:standard);	# use standard functions
   setrsh('/local/bin/ssh');
   setrcp('/local/bin/scp');

   ropen(FILE, 'host:/remote/file') or die "Open failed: $!\n";
   print while (<FILE>);
   rclose(FILE) or die "Close failed: $!\n";

   runlink('host:/remote/file');
   rmkdir('host:/remote/dir');
   rchmod('0700', 'host:/remote/dir');
   

With the function-oriented interface there is also a special tag
called I<:replace> which will actually replace the Perl builtin
functions:


   # Replace Perl's file methods with File::Remote's
   use File::Remote qw(:replace);

   open(FILE, '>host:/remote/file') or die "Open failed: $!\n";
   print FILE "Hello, world!\n";
   close(FILE) or die "Close failed: $!\n";

   mkdir('/local/new/dir', '2775');
   mkdir('host:/remote/new/dir');
   chown('root', 'other', '/local/new/dir');
   unlink('host:/remote/file');

Since File::Remote will pass calls to local files straight through
to Perl's core functions, you'll be able to do all this "transparently"
and not care about the locations of the files. Plus, as mentioned above,
this has the big advantage of making your existing Perl scripts capable
of dealing with remote files without having to rewrite any code.

=head1 FUNCTIONS

Below are each of the functions you can make use of with File::Remote.
Remember, for the function-oriented style, unless you use the I<:replace>
tag you'll have to add an extra 'r' to the start of each function name.
For all functions, the file arg can be either local or remote.

=head2 setrsh(prog) ; setrcp(prog)

These set what to use for remote shell and copy calls, needed to
manipulate remote files.  The defaults are /usr/bin/rsh and /usr/bin/rcp.
For security, you can use ssh and scp (if you have them).  In both cases,
you need to make sure you have passwordless access to the remote hosts
holding the files to be manipulated. 

=head2 settmp(dir)

This sets the directory to use for temporary files.  This is needed as
a repository during remote reads and writes.

=head2 open(handle, file) ; close(handle)

Used to open and close files just like the Perl builtins. These functions
accept both string filehandles and typeglob references.

=head2 touch(file)

Updates the modification time on a file, or creates it if it doesn't exist.

=head2 mkdir(dir [, mode]) ; rmdir(dir [, recurse])

Create a dir with optional octal mode [mode]; remove a dir tree optionally
recursively. By default, rmdir works recursively, and the mode of the new
dir from mkdir depends on your umask.

=head2 copy(file1, file2)

Simply copies a file, just like File::Copy's function of the same name.
You can also address it as 'cp' (if you import the :aliases tag).

=head2 move(file1, file2)

Moves a file ala File::Copy.  You can also address it as 'mv'
(if you import the :aliases tag).

=head2 chmod(mode, file) ; chown(owner, group, file)

Change the permissions or the owner of a file.

=head2 unlink(file)

Remove a file. You can also address it as 'rm' (if you import the :aliases tag).

=head2 backup(file, [file|suffix])

This backs up a file, useful if you're going to be manipulating it.
If you just call it without the optional second filename or suffix,
the suffix 'bkup' will be added to the file.  Either file can be local
or remote; this is really just a front-end to File::Remote::copy().

=head2 readfile(file) , writefile(file, @data)

These read and write whole files in one swoop, just like File::Slurp.
readfile() returns an array of the file, and writefile just returns
success or failure.

=head2 append(file, @data) , prepend(file, @data)

Similar to writefile(), only these don't overwrite the file, these
either append or prepend the data to the file.

=head1 EXAMPLES

Here's some more examples of how to use this module:


=head2 1. Add a new user to /etc/passwd on your server

This might be useful if you've got some type of web-based newuser
program that runs on a host other than the one you have to edit
/etc/passwd on:

   # Function-oriented method
   use File::Remote qw(:replace);

   $passwd = "server:/etc/passwd";
   backup($passwd, 'old');		# back it up to be safe
   open(PASSWD, ">>$passwd") or die "Couldn't write $passwd: $!\n";
   print PASSWD "$newuser_entry\n";
   close(PASSWD);


=head2 2. Securely copy over a bunch of files

Hopefully you would use loops and variable names to make any actual code look
much cleaner...

   # Object-oriented method
   use File::Remote
   my $secure = new File::Remote;

   # Setup secure connections and tmpdir
   $secure->setrsh('/local/bin/ssh');
   $secure->setrcp('/local/bin/scp');
   $secure->settmp('/var/stmp');

   # Move files
   $secure->move('client:/home/bob/.cshrc', 'client:/home/bob/.cshrc.old');
   $secure->copy('/etc/skel/cshrc.user', 'client:/home/bob/.cshrc');
   $secure->copy('/etc/skel/kshrc.user', 'client:/home/bob/.kshrc');
   

=head2 3. Use rsync w/ ssh for really fast transfers

Here we're assuming we're getting some huge datastream from some
other process and having to dump it into a file in realtime.
Note that the remote file won't be updated until close() is called.

   # Function-oriented, no :replace tag
   use File::Remote qw(:standard);

   setrsh('/local/bin/ssh');
   setrcp('/local/bin/rsync -z -e /local/bin/ssh');
   settmp('/var/stmp'); 

   $file = "server:/local/dir/some/huge/file";
   ropen(REMOTE, ">>$file") or die "Couldn't write $file: $!\n";
   while(<DATASTREAM>) {
      print REMOTE $_;
   }
   rclose(REMOTE);		# file is finally updated


=head1 NOTES

File::Remote only works on UNIX systems.

The main caveat to File::Remote is that you have to have rsh/rcp or ssh/scp
access to the hosts you want to manipulate files on.  Make sure you consider
the security implications of this, especially if you live outside a firewall.

Enabling autoflush ($|) won't have any effect on remote filehandles, since
the remote file is not synched until close() is called on the filehandle.

File::Remote does not support writing to remote pipes.

Because of speed, by default no checks are made as to whether or not rsh/rcp
or their equivalents are executable. To change this, see the source.

=head1 BUGS

Perl scripts that are tainted or setuid might not work with File::Remote
because of its reliance on system() calls, depending on your %ENV. To
work around this, simply add an "undef %ENV" statement to the top of
your script, which you should be doing anyways.

If you have a bug report or suggestion, please direct them to me (see below).
Please be specific and include the version of File::Remote you're using.

=head1 AUTHOR

Copyright (c) 1998-2000, Nathan Wiger (nate@sun.com). All rights reserved.

This module is free software; you may copy this under the terms of
the GNU General Public License, or the Artistic License, copies of
which should have accompanied your Perl kit.

=cut

