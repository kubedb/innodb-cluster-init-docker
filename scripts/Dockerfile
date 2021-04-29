#FROM mysql/mysql-server:8.0.24-1.2.2-server
##failure: repodata/repomd.xml from mysql80-server-minimal: [Errno 256] No more mirrors to try.
##RUN yum --disablerepo=mysql80-server-minimal ...
##RUN yum-config-manager --disable mysql80-server-minimal
##RUN yum install -y procps psmisc net-tools
#
#RUN microdnf install -y procps psmisc net-tools
#
#COPY innodb-on-start.sh /
#
##VOLUME /etc/mysql
#
## For standalone mysql
## default entrypoint of parent mysql:8.0.23
#ENTRYPOINT ["/innodb-on-start.sh"]
#
## For mysql group replication
## ENTRYPOINT ["peer-finder"]
