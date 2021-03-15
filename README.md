# Jenkins X 3.x GitOps Repository for GKE and Google Secret Manager and Gitea

This git repository installs Jenkins X with Google Secret Manager and Gitea


## Setting up

Once you are connected to your kubernetes cluster with the associated cloud infrastructure resources created run the following:

```bash 
./setup.sh
```

This script will then:

* setup nginx and gitea in your cluster
* create a new dev cluster git repository inside gitea
* install the git operator using this repository to boot up your cluster
