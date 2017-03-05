# elvanto-ldap-sync

This code will sync people changes from [Elvanto](https://www.elvanto.com) to an [openldap](http://www.openldap.org) server.

The use case is for people using Elvanto as their master contact database, who also want to use a shared (read only) LDAP server as an address book, perhaps to connect to their email client.

The sync is one way only - ie. updates only flow from Elvanto to LDAP.

Data is sourced from Elvanto using the [People API](https://www.elvanto.com/api/people/getAll/). Data is sourced from the LDAP server using [ldapsearch]( http://www.openldap.org/software/man.cgi?query=ldapsearch) and is updated in LDAP server using [ldapmodify]( http://www.openldap.org/software/man.cgi?query=ldapmodify)

## pseudocode

Elvanto Side
* retrieve JSON for all people, handle multiple pages
* reduce JSON to only the necessary fields, and convert to a single line per person

LDAP Side
* retrieve all people from LDAP server at configured location
* convert result LDIF to a single line per person

Processing
* diff the Elvanto and LDAP single-line-per-person results
* convert left diffs to LDIF adds
* convert right diffs to LDIF deletes
* convert left+right diffs to (LDIF delete + LDIF add)
* apply LDIF change file


## runtime environment

The script is written in [bash script](https://www.gnu.org/software/bash/) for a unix environment.  It requires some standard user tools; curl, awk, jq, diff etc.

It expects there to be an existing LDAP server.

Configuration is done via a config file (.elvanto-ldap-sync.config) in the home directory of the account used to run it. A sample file is provided.

The script requires write access to the /tmp directory.


## invocation

Script can be run standlone

~~~~
/home/ldapsync/elvanto-ldap-sync/sync.sh
~~~~

or on a scheduler, eg cron
~~~~
# m h  dom mon dow   command
0 10,15 * * * /home/ldapsync/elvanto-ldap-sync/sync.sh >> /var/log/ldapsync.log 2>&1
~~~~

## ldap authentication

The script supports any authentication mechanisms available command line. The authentication parameters are in the .elvanto-ldap-sync.config script and need to be setup to match your environment. In the sample below, search is done via integrated authentication (-Y EXTERNAL), and modify is setup to use user/password authentication (-D -w). In both cases below the server is running on the same server as the script (-H ldapi:///)

Note that this is an example only and you can use any parameters supported by ldapseach and ldapmodify.

~~~~
ldap.modify.params~-D "cn=admin,dc=mydomain,dc=com" -w <adminpwd> -H ldapi:///
ldap.search.params~-Y EXTERNAL -H ldapi:///
~~~~

## api authentication

The script supports [API key authentication](https://www.elvanto.com/api/getting-started/#api_key) which is setup in the .elvanto-ldap-sync.config

~~~~
elvanto.api.key=<api key>
~~~~
