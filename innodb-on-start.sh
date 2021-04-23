#!/usr/bin/env bash

# set -x

script_name=${0##*/}

#report_host the resolve host that each innodb cluster instance report to..
export report_host="$HOSTNAME.mysql-server.$namespace.svc"

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

log "INFO" "/entrypoint.sh mysqld --user=root --report-host=$report_host  $@'..."
/entrypoint.sh mysqld --user=root --report-host=$report_host $@ &

pid=$!
log "INFO" "The process id of mysqld is '$pid'"

function retry {
    local retries="$1"
    shift

    local count=0
    local wait=1
    echo "---running command $@-----------"
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
function create_replication_user() {
    # now we need to configure a replication user for each server.
    # the procedures for this have been taken by following
    # 01. official doc (section from 17.2.1.3 to 17.2.1.5): https://dev.mysql.com/doc/refman/5.7/en/group-replication-user-credentials.html
    # 02. https://dev.mysql.com/doc/refman/8.0/en/group-replication-secure-user.html
    # 03. digitalocean doc: https://www.digitalocean.com/community/tutorials/how-to-configure-mysql-group-replication-on-ubuntu-16-04
    log "INFO" "Checking whether replication user exist or not......"
    local mysql="$mysql_header"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';"
    out=$(${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}')
    # if the user doesn't exist, crete new one.
    if [[ "$out" -eq "0" ]]; then
        log "INFO" "Replication user not found. Creating new replication user........"
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=0;"
        retry 120 ${mysql} -N -e "CREATE USER 'repl'@'%' IDENTIFIED BY 'password' REQUIRE SSL;"
        retry 120 ${mysql} -N -e "GRANT ALL ON *.* TO 'repl'@'%' WITH GRANT OPTION;"
        #  You must therefore give the `BACKUP_ADMIN` and `CLONE_ADMIN` privilege to this replication user on all group members that support cloning process
        # https://dev.mysql.com/doc/refman/8.0/en/group-replication-cloning.html
        # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html
        #retry 120 ${mysql} -N -e "GRANT BACKUP_ADMIN ON *.* TO 'repl'@'%';"
        #retry 120 ${mysql} -N -e "GRANT CLONE_ADMIN ON *.* TO 'repl'@'%';"
        retry 120 ${mysql} -N -e "FLUSH PRIVILEGES;"
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=1;"

        #retry 120 ${mysql} -N -e "CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='password' FOR CHANNEL 'group_replication_recovery';"
    else
        log "INFO" "Replication user exists. Skipping creating new one......."
    fi
}

function wait_for_host_online() {
    log "INFO" "checking for host to come online..................................................."
    local mysql="mysql -uroot -ppass" # "mysql -uroot -ppass -hmysql-server-0.mysql-server.default.svc"
    retry 120 ${mysql} -N -e "select 1;" | awk '{print$1}'
    out=$(${mysql} -N -e "select 1;" | awk '{print$1}')
    if [[ "$out" -eq "0" ]]; then
        echo "--------------------------------host is online -----------------------"
    fi
    log "-----error from here -----------------"
}

function wait_for_primary_host_online() {
    log "INFO" "checking for host to come online..................................................."
    local mysql="mysql -u${replication_user} -ppassword -hmysql-server-0.mysql-server.default.svc" # "mysql -uroot -ppass -hmysql-server-0.mysql-server.default.svc"
    retry 120 ${mysql} -N -e "select 1;" | awk '{print$1}'
    out=$(${mysql} -N -e "select 1;" | awk '{print$1}')
    if [[ "$out" -eq "0" ]]; then
        echo "--------------------------------host is online -----------------------"
    fi
    log "-----error from here -----------------"
}

already_configured=0
restart_required=1
function configure_instance() {
    log "INFO" "configuring instance..........."
    local mysqlshell="mysqlsh -u${replication_user} -ppassword"
    local mysql="mysql -u${replication_user} -ppassword"
    #todo check for is cofigured first ? and set is restart_required=...
    retry 120 ${mysqlshell} --sql -e "select @@gtid_mode;"
    gtid=($($mysqlshell --sql -e "select @@gtid_mode;"))
    echo "gtid -- ${gtid[@]}"
    echo "${gtid[1]}"
    if [[ "${gtid[1]}" == "ON" ]]; then
        log "info" "---------------$report_host is already_configured-------------"
        already_configured=1
        return
    fi
    retry 120 ${mysqlshell} -e "dba.configureInstance('${replication_user}@${report_host}',{password:'password',interactive:false,restart:true});"
    restart_required=1
    #    out = $(${mysql} -e "dba.configureInstance('${replication_user}@${report_host}',{password:'password',interactive:false,restart:true});" | awk '{print$1}')
    #todo check for enforce_gtid_consistency=ON, gtid_mode=ON , server_id = (unique server id or is set?)
    #    wait_for_host_online
    #    log "info" "---------------comes here--------------"
    #    out=$(${mysql} -e "select @@enforce_gtid_consistency")
    #    echo ..............................out $out...........................

    #need to check is cluster instance configured correctly?
}
is_boostrap_able=0
function check_existing_cluster() {
    #todo need all host from peer finder then loop through
    local hosts=(mysql-server-0.mysql-server.default.svc mysql-server-1.mysql-server.default.svc mysql-server-2.mysql-server.default.svc)

    for host in ${hosts[@]}; do
        #ping in each server see is there any cluster..
        local mysqlshell="mysqlsh -u${replication_user} -ppassword -h${host} --sql"
        #retry 30 ${mysqlshell} -e "SELECT member_host FROM performance_schema.replication_group_members;"
        #  freaking_out=($(${mysqlshell} -e "SELECT member_host FROM performance_schema.replication_group_members;"))
        log "info" "-u${replication_user} -ppassword -h${host}"
        out=($(${mysqlshell} -e "SELECT member_host FROM performance_schema.replication_group_members;"))
        #out=($(mysqlsh -u${replication_user} -ppassword -h${ --sql -e "SELECT member_host FROM performance_schema.replication_group_members;"))

        echo "-------------from check_existing_cluster------------------${out[@]}------------------------------end----"
        cluster_size=${#out[@]}
        echo
        if [[ "$cluster_size" -ge "1" ]]; then
            available_host=${out[1]}
            echo "----------------available ${out[1]}--------"
            is_boostrap_able=0
            break
        else
            is_boostrap_able=1
        fi
        echo "_____________host_is_in_cluster" $host " is_boostrap_able"$is_boostrap_able "-----------------------------"
    done
}
function create_cluster() {
    #  mysqlsh -uheheh -pp -hmysql-server-0.mysql-server.default.svc -e "cluster=dba.createCluster('mycluster',{exitStateAction:'OFFLINE_MODE',autoRejoinTries:'20',consistency:'BEFORE_ON_PRIMARY_FAILOVER'});"
    #cluster=dba.createCluster("mycluster",{exitStateAction:'OFFLINE_MODE',autoRejoinTries:'20',consistency:'BEFORE_ON_PRIMARY_FAILOVER'});
    local mysqlshell="mysqlsh -u${replication_user} -ppassword -h${report_host}"
    retry 30 $mysqlshell -e "cluster=dba.createCluster('mycluster',{exitStateAction:'OFFLINE_MODE',autoRejoinTries:'20',consistency:'BEFORE_ON_PRIMARY_FAILOVER'});"
    local mysql="mysql -urepl -ppassword -hmysql-server-0.mysql-server.default.svc"
    freaking_out=$(${mysql} -N -e 'SELECT member_host FROM performance_schema.replication_group_members;')
    echo "cluster freaking_out" $freaking_out
}
available_host="not_found_for_now"

function join_in_cluster() {
    log "info " "join_in_cluster $report_host"
    #mysqlsh -uheheh -pp -hmysql-server-0.mysql-server.default.svc -e "cluster = dba.getCluster();cluster.addInstance('heheh@mysql-server-2.mysql-server.default.svc:3306',{password:'p',recoveryMethod:'clone'})";
    local mysqlshell="mysqlsh -u${replication_user} -ppassword -h${available_host}"
    out=($(${mysqlshell} --sql -e "SELECT member_host FROM performance_schema.replication_group_members;"))
    echo "_________member_host____${out[@]}-------"
    cluster_size=${#out[@]}
    if [["$cluster_size" -ge "1" ]]; then
        echo "$report_host is already in cluster"
        retun
    fi
    wait_for_primary_host_online
    retry 10 ${mysqlshell} -e "cluster = dba.getCluster();cluster.addInstance('${replication_user}@${report_host}',{password:'password',recoveryMethod:'clone'});"
    add=($(${mysqlshell} -e "cluster = dba.getCluster();cluster.addInstance('${replication_user}@${report_host}',{password:'password',recoveryMethod:'clone'});"))
    echo "-------------------------add = ${add[@]}--------------------------------------------------------"
    echo "------join--------$out--- ---${out[@]}-join-------"
    out=($(${mysqlshell} --sql -e "SELECT member_host FROM performance_schema.replication_group_members;"))
    echo "_________member_host____${out[@]}-------"

}
#create user..
#what i need is host_name, mysql_root_user , mysql_root_password , mysql command
export MYSQL_ROOT_USERNAME=root
export replication_user=repl
export replication_user_password= password
export mysql_header="mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306"
echo "----------------------------------$mysql_header----------------------------------------"

create_replication_user

# configure innodb cluster
#what i need is host_name, mysql_root_user , mysql_root_password , mysqlshell command
#mysqlsh -uheheh -pp -e "dba.configureInstance('heheh@mysql-server-0.mysql-server.default.svc:3306',{password:'p',interactive:false,restart:true});"
configure_instance

echo "**************************  need to restart mysqld"

sleep 120

#  ERROR: Remote restart of MySQL server failed: MySQL Error 3707 (HY000): Restart server failed (mysqld is not managed by supervisor process).

/entrypoint.sh mysqld --user=root --report-host=$report_host $@ &

pid=$!
log "INFO" "************************** The process id of mysqld is '$pid'"

wait_for_host_online

# # check for cluster exists
# log "INFO" "============PRE Checking=============================================== "
# check_existing_cluster
# log "INFO" "============post checking=============================================="

# log "info" "creating cluster"
# echo "is in cluster "$is_in_cluster

# #check for if the elements is all ready in cluster
# if [[ "$is_boostrap_able" -eq "1" ]];then
#  echo  "comes heere"
#  create_cluster
# else
#  join_in_cluster
# fi

log "info" "what's cause problem here "
log "_____MYSQL______" "$pid"
# wait $pid
# log "INFO" "The process id of mysqld is '$pid'"

#kill -15 $pid
#
#echo "==================================================================================================================================================="
#/entrypoint.sh mysqld --user=root --report-host=$report_host  $@ &
#
#pid=$!
#echo "enter for second time ..."
#log "INFO" "The process id of mysqld is '$pid'"
#
#create_replication_user
#configure_instance
#

if [[ "${report_host}" = "mysql-server-0.mysql-server.default.svc" ]]; then
    log "info " "${report_host} creating cluster ============================"
    create_cluster
else
    wait_for_primary_host_online
    check_existing_cluster
    join_in_cluster
    log "info" "other servers will be switching to another process .... except the primary"
fi

sleep 10000

#wait $pid
#log "info" "-----------------is pid = $pid still running -------------------------------------------"
#
#kill  -15 $pid
#
#/entrypoint.sh mysqld --user=root --report-host=$report_host  $@ &
#
#
#pid=$!
#echo "==================================================================================================================================================="
#echo "entering for third time.............."
#log "INFO" "The process id of mysqld is '$pid'"
#
##create_replication_user
##configure_instance
##check_existing_cluster
##echo is_boostrap_able "----"
###if [[ "$is_boostrap_able" -eq "1" ]];then
###  echo  "comes heere"
###  create_cluster
###else
###  join_in_cluster
###fi
##every thing should be okay by now
#
#wait $pid
