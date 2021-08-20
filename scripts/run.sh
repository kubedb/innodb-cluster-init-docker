#!/usr/bin/env bash
echo  hello > hello.txt
echo "wating for files......"
echo "--------------$@---------------"

echo " basename = $BASE_NAME,  govservice = $GOV_SVC,  namespace = $POD_NAMESPACE, db_name = $DB_NAME , host name =$HOSTNAME"

report_host="$HOSTNAME.$GOV_SVC.$POD_NAMESPACE.svc"
echo "$report_host ----------------- $POD_IP"
function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

# wait for the peer-list file created by coordinator
while [ ! -f "/scripts/peer-list" ]; do
    log "WARNING" "peer-list is not created yet"
    sleep 1
done

hosts=$(cat "/scripts/peer-list")

log "INFO" "hosts are {$hosts}"
cat >>/etc/my.cnf <<EOL
default_authentication_plugin=mysql_native_password
EOL



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
function create_user() {

    mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED with mysql_native_password by '${MYSQL_ROOT_PASSWORD}';"
    mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' REQUIRE SSL;"
    mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "GRANT ALL ON *.* TO 'repl'@'%' WITH GRANT OPTION;"
    mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;"
    mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "flush privileges;"

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
primary=""
function select_primary() {

    for host in "${hosts[@]}"; do
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

function join_in_cluster() {
    log "INFO " "$report_host joining in cluster"

    #cheking for instance can rejoin during a fail-over
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
#    ${mysqlshell} -e "cluster=dba.getCluster(); cluster.rejoinInstance('${replication_user}@${report_host}',{password:'${MYSQL_ROOT_PASSWORD}'})"
#    ${mysqlshell} -e "cluster = dba.getCluster();  cluster.rescan({addInstances:['${report_host}:3306'],interactive:false})"
#    wait_for_host_online "repl" "$report_host" "${MYSQL_ROOT_PASSWORD}"
    #add a new instance

    ${mysqlshell} -e "cluster = dba.getCluster();cluster.addInstance('${replication_user}@${report_host}',{password:'${MYSQL_ROOT_PASSWORD}',recoveryMethod:'clone'});"

    # Prevent creation of new process until this one is finished
    #https://serverfault.com/questions/477448/mysql-keeps-crashing-innodb-unable-to-lock-ibdata1-error-11
    wait $pid

}



replication_user=repl

/entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $@ &
wait_for_host_online "root" "localhost" "$MYSQL_ROOT_PASSWORD"
create_user
configure_instance
if [[ "$restart_required" == "1" ]]; then

    log "INFO" "/entrypoint.sh mysqld --user=root --report-host=$report_host  $@'..."
    /entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $@ &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
    wait_for_host_online "repl" "$report_host" "$MYSQL_ROOT_PASSWORD"
fi


# wait for the script copied by coordinator
while [ ! -f "/scripts/signal.txt" ]; do
    log "WARNING" "signal is not present yet!"
    sleep 1
done
desired_func=$(cat /scripts/signal.txt)
echo $desired_func
if [[ $desired_func == "create_cluster" ]];then
  create_cluster
fi

if [[ $desired_func == "join_in_cluster" ]];then
  select_primary
  join_in_cluster
  log "INFO" "/entrypoint.sh mysqld --user=root --report-host=$report_host  $@'..."
  /entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $@ &
  pid=$!
  log "INFO" "The process id of mysqld is '$pid'"
  wait_for_host_online "repl" "$report_host" "${MYSQL_ROOT_PASSWORD}"
fi
#if signal == '1'{
#  create_cluster
#}
#if signal == 2{
#  joincluster
#}
#if signal == 3{
#  reboot_from_complete_outrage
#}
#wait for create cluster scirpts
#wait for join cluster scipts
#wait for reboot from complete outrage
sleep 100000

}