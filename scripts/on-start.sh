#!/usr/bin/env bash

#set -x
# Environment variables passed from Pod env are as follows:
#
#   GROUP_NAME          = a uuid treated as the name of the replication group
#   DB_NAME             = name of the database CR
#   BASE_NAME           = name of the StatefulSet (same as the name of CRD)
#   GOV_SVC             = the name of the governing service
#   POD_NAMESPACE       = the Pods' namespace
#   MYSQL_ROOT_USERNAME = root user name
#   MYSQL_ROOT_PASSWORD = root password
#   HOST_ADDRESS        = Address used to communicate among the peers. This can be fully qualified host name or IPv4 or IPv6
#   HOST_ADDRESS_TYPE   = Address type of HOST_ADDRESS (one of DNS, IPV4, IPv6)
#   POD_IP              = IP address used to create whitelist CIDR. For HOST_ADDRESS_TYPE=DNS, it will be status.PodIP.
#   POD_IP_TYPE         = Address type of POD_IP (one of IPV4, IPv6)

script_name=${0##*/}
echo "host address == $HOST_ADDRESS, Host adress type = $HOST_ADDRESS_TYPE"

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

cur_hostname=$POD_IP
export cur_host=
log "INFO" "Reading standard input..."
function find_peers() {
    while read -ra line; do
        if [[ "${line}" == *"${cur_hostname}"* ]]; then
            cur_host=$(echo -n ${line} | sed -e "s/.svc.cluster.local//g")
            log "INFO" "I am $cur_host"
        fi
        tmp=$(echo -n ${line} | sed -e "s/.svc.cluster.local//g")
        peers=("${peers[@]}" "$tmp")
    done
    log "INFO" "Trying to start group with peers'${peers[*]}'"
}

myhost=$POD_IP
report_host="yet to set"
# find aliases form etc/hosts file
while read -r -u9 line; do
    pod_ip=$(echo $line | cut -d' ' -f 1)
    echo $pod_ip
    if [[ $pod_ip == $myhost ]]; then
        report_host=$(echo $line | cut -d' ' -f 2)
        echo $report_host
    fi
done 9<'/etc/hosts'

function retry {
    local retries="$1"
    shift
    local count=0
    local wait=1
    until "$@"; do
        exit="$?"
        if [ $count -lt $retries ]; then
            log "INFO" "Attempt $count/$retries. Command exited with exit_code: $exit. Retrying after $wait seconds..."
            sleep $wait
        else
            log "INFO" "Command failed in all $retries attempts with exit_code: $exit. Stopping trying any further...."
            return $exit
        fi
        count=$(($count + 1))
    done
    return 0
}
# recoverable set to true if replication user exists means the instance was a member of the cluster before.
recoverable=0
function create_replication_user() {
    # MySql server's need a replication user to communicate with each other
    # 01. official doc (section from 17.2.1.3 to 17.2.1.5): https://dev.mysql.com/doc/refman/5.7/en/group-replication-user-credentials.html
    # 02. https://dev.mysql.com/doc/refman/8.0/en/group-replication-secure-user.html
    # 03. digitalocean doc: https://www.digitalocean.com/community/tutorials/how-to-configure-mysql-group-replication-on-ubuntu-16-04
    log "INFO" "Checking whether replication user exist or not..."
    local mysql="mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';"
    out=$(${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}')
    # if the user doesn't exist, crete new one.
    if [[ "$out" -eq "0" ]]; then
        log "INFO" "Replication user not found. Creating new replication user..."
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=0;"
        retry 120 ${mysql} -N -e "CREATE USER 'repl'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' REQUIRE SSL;"
        retry 120 ${mysql} -N -e "GRANT ALL ON *.* TO 'repl'@'%' WITH GRANT OPTION;"
        # it seems mysql-server docker image doesn't has the user root that can connect from any host
        retry 120 ${mysql} -N -e "CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';"
        # todo use specific permission needed for replication user.
        retry 120 ${mysql} -N -e "GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;"
        #  You must therefore give the `BACKUP_ADMIN` and `CLONE_ADMIN` privilege to this replication user on all group members that support cloning process
        # https://dev.mysql.com/doc/refman/8.0/en/group-replication-cloning.html
        # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html
        #retry 120 ${mysql} -N -e "GRANT BACKUP_ADMIN ON *.* TO 'repl'@'%';"
        #retry 120 ${mysql} -N -e "GRANT CLONE_ADMIN ON *.* TO 'repl'@'%';"
        retry 120 ${mysql} -N -e "FLUSH PRIVILEGES;"
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=1;"

    #retry 120 ${mysql} -N -e "CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='password' FOR CHANNEL 'group_replication_recovery';"
    else
        recoverable=1
        log "INFO" "Replication user exists. Skipping creating new one......."
    fi
}

function wait_for_host_online() {
    #function called with parameter user,host,password
    log "INFO" "checking for host $2 to come online"

    local mysqlshell="mysqlsh -u$1 -h$2 -p$3" # "mysql -uroot -ppass -hmysql-server-0.mysql-server.default.svc"
    retry 900 ${mysqlshell} --sql -e "select 1;" | awk '{print$1}'
    out=$(${mysqlshell} --sql -e "select 1;" | head -n1 | awk '{print$1}')
    if [[ "$out" == "1" ]]; then
        log "INFO" "host $2 is online"
    else
        log "INFO" "server failed to comes online within 900 seconds"
    fi

}

primary="not_found"
function select_primary() {

    for host in "${peers[@]}"; do
        local mysqlshell="mysqlsh -u${replication_user} -h${host} -p${MYSQL_ROOT_PASSWORD}"
        #result of the query output "member_host host_name" in this format
        selected_primary=($($mysqlshell --sql -e "SELECT member_host FROM performance_schema.replication_group_members where member_role = 'PRIMARY' ;"))

        if [[ "${#selected_primary[@]}" -ge "1" ]]; then
            primary=${selected_primary[1]}
            log "INFO" "Primary found $primary."
            return
        fi
    done
    log "INFO" "Primary not found."
}

function wait_for_primary_host_online() {
    log "INFO" "checking for host primary ${primary} to come online..."

    local mysqlshell="mysqlsh -u${replication_user} -ppassword -h${primary}" # "mysql -uroot -ppass -hmysql-server-0.mysql-server.default.svc"
    retry 900 ${mysqlshell} --sql -e "select 1;" | awk '{print$1}'
    out=$(${mysqlshell} --sql -e "select 1;" | head -n1 awk '{print$1}')
    if [[ "$out" == "1" ]]; then
        log "INFO" "Primary host $primary is online."
    else
        log "INFO" "Primary host ${primary} failed to come online."
    fi
}

restart_required=0
already_configured=0

function configure_instance() {
    log "INFO" "configuring instance $report_host."
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD}"

    retry 120 ${mysqlshell} --sql -e "select @@gtid_mode;"
    gtid=($($mysqlshell --sql -e "select @@gtid_mode;"))
    if [[ "${gtid[1]}" == "ON" ]]; then
        log "INFO" "$report_host is already_configured."
        already_configured=1
        return
    fi

    retry 30 ${mysqlshell} -e "dba.configureInstance('${replication_user}@${report_host}',{password:'${MYSQL_ROOT_PASSWORD}',interactive:false,restart:true});"
    #instance need to restart after configuration
    # Prevent creation of new process until this one is finished
    #https://serverfault.com/questions/477448/mysql-keeps-crashing-innodb-unable-to-lock-ibdata1-error-11
    #The most common cause of this problem is trying to start MySQL when it is already running.
    wait $pid
    restart_required=1
}

function create_cluster() {
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${report_host}"
    retry 5 $mysqlshell -e "cluster=dba.createCluster('mycluster',{exitStateAction:'OFFLINE_MODE',autoRejoinTries:'20',consistency:'BEFORE_ON_PRIMARY_FAILOVER'});"
}

already_in_cluster=0

function is_already_in_cluster() {
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    ${mysqlshell} -e "cluster = dba.getCluster();  cluster.rescan({addInstances:['${report_host}:3306'],interactive:false})"
    out=($(${mysqlshell} --sql -e "SELECT member_host FROM performance_schema.replication_group_members where member_state='ONLINE';"))

    for host in ${out[@]}; do
        if [[ "$host" == "$report_host" ]]; then
            echo "$report_host is already in cluster"
            already_in_cluster=1
            return
        fi
    done
}

function join_in_cluster() {
    log "INFO " "$report_host joining in cluster"

    #cheking for instance can rejoin during a fail-over
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    ${mysqlshell} -e "cluster=dba.getCluster(); cluster.rejoinInstance('${replication_user}@${report_host}',{password:'${MYSQL_ROOT_PASSWORD}'})"
    ${mysqlshell} -e "cluster = dba.getCluster();  cluster.rescan({addInstances:['${report_host}:3306'],interactive:false})"
    wait_for_host_online "repl" "$report_host" "${MYSQL_ROOT_PASSWORD}"
    is_already_in_cluster

    if [[ "$already_in_cluster" == "1" ]]; then
        wait $pid
    fi

    #add a new instance

    ${mysqlshell} -e "cluster = dba.getCluster();cluster.addInstance('${replication_user}@${report_host}',{password:'${MYSQL_ROOT_PASSWORD}',recoveryMethod:'clone'});"

    # Prevent creation of new process until this one is finished
    #https://serverfault.com/questions/477448/mysql-keeps-crashing-innodb-unable-to-lock-ibdata1-error-11
    wait $pid

}
function make_sure_instance_join_in_cluster() {
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    retry 10 ${mysqlshell} -e "cluster = dba.getCluster();  cluster.rescan({addInstances:['${report_host}:3306'],interactive:false})"
    out=($(${mysqlshell} --sql -e "SELECT member_host FROM performance_schema.replication_group_members;"))

    for host in "${out[@]}"; do
        if [[ "$host" == "$report_host" ]]; then
            echo "$report_host successfully join_in_cluster"
        fi
    done
}

function dropMetadataSchema() {
    #mysqlsh -urepl -hmysql-server-0.mysql-server.default.svc -ppassword -e "dba.dropMetadataSchema({force:true})"
    local mysqlshell="mysqlsh -u${replication_user} -h${report_host} -p${MYSQL_ROOT_PASSWORD}"
    retry 3 $mysqlshell --sql -e "stop group_replication;"
    retry 3 $mysqlshell --sql -e "reset master;"
    retry 3 $mysqlshell --sql -e "set global group_replication_group_seeds='';"
    retry 3 $mysqlshell -e "dba.dropMetadataSchema({force:true,clearReadOnly:true})"
}

function reboot_from_completeOutage() {
    local mysqlshell="mysqlsh -u${replication_user} -h${report_host} -p${MYSQL_ROOT_PASSWORD}"
    #https://dev.mysql.com/doc/dev/mysqlsh-api-javascript/8.0/classmysqlsh_1_1dba_1_1_dba.html#ac68556e9a8e909423baa47dc3b42aadb
    #mysql wait for user interaction to remove the unavailable seed from the cluster..
    yes | $mysqlshell -e "dba.rebootClusterFromCompleteOutage('mycluster',{user:'repl',password:'${MYSQL_ROOT_PASSWORD}',rejoinInstances:['$report_host']})"
    yes | $mysqlshell -e "cluster = dba.getCluster();  cluster.rescan()"
    wait $pid
}

export MYSQL_ROOT_USERNAME=root
export replication_user=repl

find_peers

# starting mysqld in background
log "INFO" "/entrypoint.sh mysqld --user=root --report-host=$report_host  $@'..."
/entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $@ &
pid=$!
log "INFO" "The process id of mysqld is '$pid'"

wait_for_host_online "root" "localhost" "$MYSQL_ROOT_PASSWORD"

create_replication_user

wait_for_host_online "repl" "$report_host" "${MYSQL_ROOT_PASSWORD}"

configure_instance

if [[ "$restart_required" == "1" ]]; then
    #    log "INFO" "--------------------------------after configuration----------------------------"
    log "INFO" "/entrypoint.sh mysqld --user=root --report-host=$report_host  $@'..."
    /entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $@ &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
    wait_for_host_online "repl" "$report_host" "$MYSQL_ROOT_PASSWORD"
fi

select_primary

if [[ "$primary" == "not_found" ]]; then

    if [[ "$recoverable" == "1" ]]; then
        retry 2 reboot_from_completeOutage
    else
        create_cluster
        wait_for_host_online "repl" "$report_host" "${MYSQL_ROOT_PASSWORD}"
    fi
else
    log "INFO" "---------------------------host $report_host will join as secondary member ------------------------------"
    join_in_cluster
    # MySQL can't restart itself inside Docker image. So, we restart it directly.
    log "INFO" "/entrypoint.sh mysqld --user=root --report-host=$report_host  $@'..."
    /entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $@ &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
    wait_for_host_online "repl" "$report_host" "${MYSQL_ROOT_PASSWORD}"
    make_sure_instance_join_in_cluster
    echo "running pid of mysqld  $pid"
    wait $pid
fi

wait $pid
