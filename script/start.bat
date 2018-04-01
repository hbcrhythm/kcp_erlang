@echo off
cd ..\
rebar3 auto --name hbc@127.0.0.1 --setcookie 123456 --apps kcp_erlang