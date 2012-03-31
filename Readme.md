Multipkg
==============
Multipkg automates and versions your package builds.

Installation
--------------
Multipkg is best installed via rpms/debs built by... Multipkg.

The bootstrap process is a little primitive now, but here are the steps:

1. install cpan
<pre>
yum -y install perl-CPAN
</pre>
1. Install your developer tools
  * might be unnecessary now
  * yum -y groupinstall "Development Tools"
1. install YAML::Syck
<pre>
  * yum install perl-YAML-Syck
</pre>
1. git clone multipkg
1. cd multipkg
1. manually build and install your first multipkg package
<pre>
PREFIX=./root PKGVERID=0 INSTALL_DIR=source scripts/transform
perl -I ./source/lib root/usr/bin/multipkg -t .
sudo yum -y install multipkg-*rpm
</pre>
1. Remove the first package
<pre>
  * rm multipkg*rpm
</pre>
1. Build your final multipkg package from git
<pre>
  * git-multipkg -b https://github.com/ytoolshed/ multipkg
</pre>
1. ENJOY
