FROM mysql/mysql-server:8.0.23

RUN yum install -y procps psmisc net-tools

COPY innodb-on-start.sh /

#VOLUME /etc/mysql

# For standalone mysql
# default entrypoint of parent mysql:8.0.23
ENTRYPOINT ["/innodb-on-start.sh"]

# For mysql group replication
# ENTRYPOINT ["peer-finder"]
