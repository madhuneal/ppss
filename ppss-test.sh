#!/bin/bash

DEBUG="$1"
VERSION=2.45

cleanup () {

    for x in $REMOVEFILES
    do
        if [ -e ./$x ]
        then
            rm -r ./$x
        fi
    done
}

oneTimeSetUp () {

	NORMALTESTFILES=`echo test-{a..z}`
    SPECIALTESTFILES="\'file-!@#$%^&*()_+=-0987654321~\' \'file-/\<>?:;'{}[]\' file-/\/\:\/!@#$%^&*()_+=-0987654321~ file-/\<>?:;'{}[] http://www.google.nl ftp://storage.nl"
	JOBLOG=./ppss/job_log
	INPUTFILENORMAL=test-normal.input
    INPUTFILESPECIAL=test-special.input
    LOCALOUTPUT=ppss/PPSS_LOCAL_OUTPUT

	REMOVEFILES="$INPUTFILENORMAL $INPUTFILESPECIAL ppss test-ppss-*"

    cleanup

	for x in $NORMALTESTFILES
	do
		echo "$x" >> "$INPUTFILENORMAL"
	done

    for x in $SPECIALTESTFILES
    do
        echo $x >> "$INPUTFILESPECIAL"
    done
}

testVersion () {

    RES=`./ppss.sh -v`
    
    for x in $RES
    do
        echo "$x" | grep [0-9] >> /dev/null
        if [ "$?" == "0" ]
        then
            assertEquals "Version mismatch!" "$VERSION" "$x"
        fi
    done
}

rename-ppss-dir () {

	TEST="$1"

	if [ -e "ppss" ] && [ -d "ppss" ] && [ ! -z "$TEST" ]
	then
		mv ppss test-ppss-"$TEST"
	fi
}

oneTimeTearDown () {

	if [ ! "$DEBUG" == "debug" ]
	then
        cleanup 
    fi
}

testSpecialCharacterHandling () {

    RES=$( { ./ppss.sh -f "$INPUTFILESPECIAL" -c 'echo ' >> /dev/null ; } 2>&1 )  
	assertEquals "PPSS did not execute properly." 0 "$?"

    assertNull "PPSS retured some errors..." "$RES"
    if [ ! "$?" == "0" ]
    then
        echo "RES IS $RES"
    fi

    RES=`find ppss/PPSS_LOCAL_OUTPUT | wc -l`
    assertEquals "To many lock files..." "7" "$RES"

    RES1=`ls -1 $JOBLOG`
    RES2=`ls -1 $LOCALOUTPUT`

    assertEquals "RES1 $RES1 is not the same as RES2 $RES2" "$RES1" "$RES2"

    rename-ppss-dir $FUNCNAME
}

testExistLogFiles () {

	./ppss.sh -f "$INPUTFILENORMAL" -c 'echo "$ITEM"' >> /dev/null
	assertEquals "PPSS did not execute properly." 0 "$?"

	for x in $NORMALTESTFILES
	do
		assertTrue "[ -e $JOBLOG/$x ]"
	done

	rename-ppss-dir $FUNCNAME
}

getStatusOfJob () {

	EXPECTED="$1"

	if [ "$EXPECTED" == "SUCCESS" ]
	then
		./ppss.sh -f "$INPUTFILENORMAL" -c 'echo ' >> /dev/null
        	assertEquals "PPSS did not execute properly." 0 "$?"
	elif [ "$EXPECTED" == "FAILURE" ]
	then
		./ppss.sh -f "$INPUTFILENORMAL" -c 'thiscommandfails ' >> /dev/null
        	assertEquals "PPSS did not execute properly." 0 "$?"
	fi

	for x in $NORMALTESTFILES
	do
		RES=`grep "Status:" "$JOBLOG/$x"`
        STATUS=`echo "$RES" | awk '{ print $2 }'`
        assertEquals "FAILED WITH STATUS $STATUS." "$EXPECTED" "$STATUS"
    done

	rename-ppss-dir "$FUNCNAME-$EXPECTED"
}


testErrorHandlingOK () {

	getStatusOfJob SUCCESS
}

testErrorHandlingFAIL () {

	getStatusOfJob FAILURE
}




. ./shunit2
