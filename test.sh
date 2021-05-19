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

#function wait_for_host() {
#    echo $1
#    echo $2
#
#}
#wait_for_host "root" "localhost"
#report_host="12.3.4.4"
#wait_for_host "repl" "$report_host"
#
#
#
#cat >>/etc/hosts <<EOL
##self added node name
#fc00:f853:ccd:e793::3 kind-worker3
#fc00:f853:ccd:e793::4 kind-worker
#fc00:f853:ccd:e793::5 kind-worker2
#
#EOL
#
#
myhost=fc00:f853:ccd:e793::2
while read -r -u9 line; do
    pod_ip=$(echo $line | cut -d' ' -f 1)
    echo $pod_ip
    if [[ $pod_ip == $myhost ]]; then
        report_host=$(echo $line | cut -d' ' -f 2)
        echo $report_host
    fi
done 9<'/etc/host'
