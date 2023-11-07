FROM centos:centos7

ARG RSYNC_VERSION=v3.2.7

RUN yum -y install \
epel-release \
git \
lz4-devel \
lz4-static \
openssl-static \
python3-pip \
python3-devel \
glibc-static \
popt-devel \
popt-static \
make \
automake \
gcc \
wget \ 
doxygen \
rpm-build

RUN yum -y install \
libzstd-devel \
libzstd \
libzstd-static \
xxhash-devel \
&& \
python3 -mpip install --user commonmark

RUN cd / && \ 
wget https://download-ib01.fedoraproject.org/pub/epel/7/SRPMS/Packages/x/xxhash-0.8.2-1.el7.src.rpm && \
rpm -ivh xxhash-*.el7.src.rpm && \
cd ~/rpmbuild/SPECS && \
rpmbuild -bp xxhash.spec && \
cd ~/rpmbuild/BUILD/xxHash-*/ && \
make install

RUN cd / && \
git clone https://github.com/WayneD/rsync.git && \
cd rsync && \
git checkout $RSYNC_VERSION
 
WORKDIR /rsync

RUN cd /rsync && \
LIBS="-ldl" ./configure && \
make -B CFLAGS="-static" 

RUN echo If build was successful, below output should state: 'not a dynamic executable' && \
ldd rsync || \
true
