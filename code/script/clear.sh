#! /bin/bash
mosquitto_sub -h 192.168.0.51 -p 1883 -u test -P 123456 -t server/request --remove-retained -W 1
mosquitto_sub -h 192.168.0.51 -p 1883 -u test -P 123456 -t server/response --remove-retained -W 1
mosquitto_sub -h 192.168.0.51 -p 1883 -u test -P 123456 -t nckhsv/+/request --remove-retained -W 1
mosquitto_sub -h 192.168.0.51 -p 1883 -u test -P 123456 -t nckhsv/+/response --remove-retained -W 1
mosquitto_sub -h 192.168.0.51 -p 1883 -u test -P 123456 -t nckhsv/+/select --remove-retained -W 1
exit 0
