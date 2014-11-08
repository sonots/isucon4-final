#!/bin/sh

source /home/isucon/env_variables.sh
sudo rm -rf /dev/shm/public
sudo cp -ra /home/isucon/webapp/public /dev/shm/public


[ ! -d $GOPATH/src ] && mkdir -p $GOPATH/src

exec $*
