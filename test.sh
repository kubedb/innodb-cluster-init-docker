#!/bin/bash
hosts=(mysql-server-0.mysql-server.test.svc mysql-server-1.mysql-server.test.svc mysql-server-2.mysql-server.test.svc)
echo ${hosts[@]}
for item in ${hosts[@]};do
  echo $item
done
hell="-n OFF"
lleh="-n hell"
if [[ "$hell" == "OFF" ]];then
  echo $hell "def"
fi