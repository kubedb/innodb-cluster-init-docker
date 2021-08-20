#!/usr/bin/env bash

if [ -z "$(ls -A /var/lib/mysql)" ]; then
    echo -n "Empty"
else
    echo -n "Not Empty"
fi
