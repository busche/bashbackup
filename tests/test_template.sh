#!/bin/bash

BASE_PATH=.
function check_base_path(){
	SCRIPT=${BASE_PATH}/scripts/template.sh
	return `test -f ${SCRIPT}`
}
check_base_path
if [ ! $? = 0 ]; then
	BASE_PATH=..
fi
check_base_path
if [ ! $? = 0 ]; then
	echo "failed to get BASE_PATH. Run this script either from the project root, or from tests/"
	exit 1
fi

SCRIPT=${BASE_PATH}/scripts/template.sh
CONFIGS=${BASE_PATH}/tests/config.test_template/
if [ ! -f ${SCRIPT} ]; then
	echo "${SCRIPT} does not exist."
	exit 2
fi

TEST_BASE_DIR=${CONFIGS} ${SCRIPT} ${CONFIGS}/local.config
if [ ! $? = 0 ]; then
	# error while running backup script
	echo "Backup script failed!"
	exit 1
fi
diff --exclude=detail.log --exclude=summary.log tests/config.test_template/actual_target/????????_??????/ tests/config.test_template/expected_target/
if [ ! $? = 0 ]; then
	echo "Test failed!"
else
	echo "Test successful!"
	rm -rf tests/config.test_template/actual_target/*
fi

