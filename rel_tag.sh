#!/bin/bash

export BRANCH_A=main
export BRANCH_B=origin/main


if [ x"$(git rev-parse $BRANCH_A)" != x"$(git rev-parse $BRANCH_B)" ]
then
    echo $BRANCH_A and $BRANCH_B are not the same
    exit 1
fi

export TAG=$(date -I).$(expr $(git tag | wc -l) + 1)
git tag $TAG
git push origin $TAG
