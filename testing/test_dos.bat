@echo off
rem $Id$
erase run_test.out
for %%n in ( case*.bat ) do call %%n
