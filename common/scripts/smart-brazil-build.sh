#!/bin/bash
dirname=$(basename "$PWD")

if [[ "$dirname" == "EbsServer" ]]; then
    brazil-build rpm
elif [[ "$dirname" == "EbsTodTestRunner" ]]; then
    echo "Skipping $dirname (noop)"
else
    brazil-build
fi
