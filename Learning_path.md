* [ci-tools](https://github.com/openshift/ci-tools)

| Image              | Command Source | Command Binary in the image | Used in Makefile Target |
| :---------------- | :------: | ----: | ----: |
| quay.io/openshift/ci-public:`ci_determinize-ci-operator_latest`       |   [cmd/determinize-ci-operator](https://github.com/openshift/ci-tools/blob/master/cmd/determinize-ci-operator/main.go)   | `/usr/bin/determinize-ci-operator` | openshift/release:`ci-operator-config` |

