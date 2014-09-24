A curlable API wrapper to vSphere
=================================

Wrote this a couple months back as a quick test.  I wanted to see how realistic doing something like this would be as an interim solution for VM provisioning while we work out our OpenStack deployment.  It turned out that basic functionality was really easy to achieve but for one reason or another the application never got deployed.  Now it has been.
Code

* https://github.com/puppetlabs/vmwr

Examples
--------

*Create VM: (Debian 7 using default g1.micro flavor)*

`curl -X POST -H "Authorization: Basic $API_KEY" "https://vmware-vmwr1.ops.puppetlabs.net/v1/operations/deployed-test"`

*Create VM: (CentOS 7 using c1.large flavor)*

`curl -X POST -H "Accept: application/json" -d "{ \"flavor\":\"c1.large\", \"template\":\"centos-7-x86_64\" }" -H "Authorization: Basic $API_KEY" "https://vmware-vmwr1.ops.puppetlabs.net/v1/operations/deployed-test"`

*Destroy VM:*

`curl -X DELETE -H "Authorization: Basic $API_KEY" "https://vmware-vmwr1.ops.puppetlabs.net/v1/operations/deployed-test"`

*Reboot VM:*

`curl -H "Authorization: Basic $API_KEY" "https://vmware-vmwr1.ops.puppetlabs.net/v1/operations/deployed-test/reboot"`

*Get some info as JSON: (no key needed, uses read-only account)*

`curl "https://vmware-vmwr1.ops.puppetlabs.net/v1/operations/deployed-test/info`

*Get instance ipaddress: (no key needed, uses read-only account)*

`curl "https://vmware-vmwr1.ops.puppetlabs.net/v1/operations/deployed-test/info/ipAddress`


API Key
-------

$USERNAME@puppetlabs.com:$PASSWORD" base64 encoded

a.k.a. basic auth, you can also use curl's -u option.  I like base64ing my password because it makes them URL and shell safe


Flavors
-------

|name|memory (MB)|cores|
|----|-----------|-----|
|g1.micro|1024|1|
|m1.small|2048|1|
|m1.medium|4096|2|
|m1.large|6144|4|
|c1.small|1024|2|
|c1.medium|2048|4|
|c1.large|4096|6|

