#!/bin/bash
#hosts=(mysql-server-0.mysql-server.test.svc mysql-server-1.mysql-server.test.svc mysql-server-2.mysql-server.test.svc)
#echo ${hosts[@]}
#for item in ${hosts[@]}; do
#    echo $item
#done
#hell="-n OFF"
#lleh="-n hell"
#if [[ "$hell" == "OFF" ]]; then
#    echo $hell "def"
#fi

function wait_for_host() {
    echo $1
    echo $2

}
wait_for_host "root" "localhost"
report_host="12.3.4.4"
wait_for_host "repl" "$report_host"
