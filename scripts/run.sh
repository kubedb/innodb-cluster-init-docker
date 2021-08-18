#!/usr/bin/env bash

echo "wating for files......"
echo "--------------$@---------------"

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}


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

mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' REQUIRE SSL;"
mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' REQUIRE SSL;"
mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "GRANT ALL ON *.* TO 'repl'@'%' WITH GRANT OPTION;"
#mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;"
mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e "flush privileges;"

}
/entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $@ &
wait_for_host_online "root" "localhost" "$MYSQL_ROOT_PASSWORD"
create_user

sleep 100000