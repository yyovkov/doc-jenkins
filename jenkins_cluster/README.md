# Jenkins PaceMaker Cluster

## General Info

Creating Jenkins two node Cluster, based on Linux pacemaker.  
Cluster have one active and one passive node. In case of failure of the active node, all the resources (ip address, 

## NOTE

DRDB driver version might need to be tweaked, depending on the CentOS 7 version and patchlevel. I.e. if the machine is not in isolated environment, better to enalbe ELREPO on it, and let the machine to chose the correct driver itself. If not, check which version best will suit your kernel. It could be advised to disable kernel updates, as with the kernel update, where the _drdb_ driver has not release yet, the cluster will not work.

## Requirements

* Two Linux (CentOS) server `node-a` and `node-b`
* Each node has two network interfaces and networks:
  * Inter-node connection (best result with dedicated network)
  * Network for public service (Jenksin in this case)

## Implementation
Run the the scripts one by one. First one should be executed on the passive node, then one on the active mode shoult take place. Additional files, next to the scripts are expected to be copied on active node, before the script execution.
