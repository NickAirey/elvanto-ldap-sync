#!/bin/bash

date

TMPDIR=$(mktemp -d /tmp/tmp.XXXX)

LDAPSEARCH=$TMPDIR/ldapsearch
LDAPSORTED=$LDAPSEARCH.sort

EL_SEARCH_PAGE=$TMPDIR/elsearch_page
EL_SEARCH_PAGE_RAW=$TMPDIR/elsearch_page.raw
EL_SEARCH=$TMPDIR/elsearch
EL_SORTED=$TMPDIR/elsearch.sort

DIFFS1=$TMPDIR/diffs.1col
LDIF=$TMPDIR/ldif
LANG=en_AU.UTF-8

LDAP_PEOPLE_LOC=$(awk -F~ '/ldap.people.location/ {print $2}' ~/.config)
LDAP_MODIFY_PARAMS=$(awk -F~ '/ldap.modify.params/ {print $2}' ~/.config)
LDAP_SEARCH_PARAMS=$(awk -F~ '/ldap.search.params/ {print $2}' ~/.config)
API_KEY=$(awk -F= '/elvanto.api.key/ {print $2}' ~/.config)

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH

# helper regex to convert a single line dn into a multline LDIF delete
REGEX_DN_TO_LDIF_DEL='s/^(.*)$/\n# delete record\n\1\nchangetype: delete/g'

# helper regex to convert a single line pipe record to multiline LDIF add
REGEX_PIPE_RECORD_TO_LDIF_INS='s/^(.*?)\|(.*)$/\n# insert record\n\1\nchangetype: add\n\2/ ; s/\|/\n/g'


# ---- first get elvanto's db entries, which are considered the master

PAGE=1
ON_THIS_PAGE=1
while [[ $ON_THIS_PAGE -gt 0 && $PAGE -lt 100 ]]; do

   HTTP_RC=$(curl -s -w '%{http_code}' -o $EL_SEARCH_PAGE_RAW -u "${API_KEY}:x" "https://api.elvanto.com/v1/people/getAll.json?page=${PAGE}")
   ON_THIS_PAGE=$(jq '.people.on_this_page' $EL_SEARCH_PAGE_RAW)
   STATUS=$(jq '.status' $EL_SEARCH_PAGE_RAW)

   echo PAGE=$PAGE ON_THIS_PAGE=$ON_THIS_PAGE
   #echo STATUS=$STATUS
   #echo HTTP_RC=$HTTP_RC

   if [[ $HTTP_RC -gt 200 ]]; then
      echo http error: $HTTP_RC
      exit $HTTP_RC
   fi

   if [ "$STATUS" != "\"ok\"" ]; then
      echo elvanto returned error status :$STATUS
      exit 9 
   fi

   # process the raw json to extract the fields we need
   jq --arg domain ${LDAP_PEOPLE_LOC} -c '.people.person[] | { dn: ("uid="+.id+","+$domain), objectClass: "inetOrgPerson", cn: (.firstname+" "+.lastname), givenName: .firstname, sn: .lastname, homePhone: .phone, mobile: .mobile, mail: .email, uid: .id }' $EL_SEARCH_PAGE_RAW > $EL_SEARCH_PAGE
   RC=$?
   if [[ $RC > 0 ]]; then
      echo jq non zero RC: $RC
      exit $RC
   fi

   # turn extracted json into pipe delimited single-line-ldif 
   perl -pi -e 's/,?\"(\w+)\":/\|$1: /g ; s/^{\|// ; s/}$// ; s/\"//g' $EL_SEARCH_PAGE

   # remove null or empty attributes
   perl -pi -e 's/\w+: null\|//g; s/\w+: \|//g' $EL_SEARCH_PAGE

   # append these search results to master list
   cat $EL_SEARCH_PAGE >> $EL_SEARCH

   (( PAGE ++ ))
done

# sort to be sure of a consistent order 
sort $EL_SEARCH > $EL_SORTED

#echo el_sorted
wc -l $EL_SORTED

# ---- now get the ldap entries to be compared and updated

ldapsearch ${LDAP_SEARCH_PARAMS} -b "${LDAP_PEOPLE_LOC}" -LLL '(objectclass=inetOrgPerson)' dn objectClass uid cn givenName sn homePhone mobile mail > $LDAPSEARCH
RC=$?
 if [[ $RC > 0 ]]; then
   echo ldap search non zero RC: $RC
   exit $RC
fi

# turn ldif into single line per entry and pipe delimited

perl -p0i -e 's/\n //g ; s/\n/|/g' $LDAPSEARCH
perl -pi -e 's/\|\|/\n/g' $LDAPSEARCH

# sort to be sure of a consistent order
sort $LDAPSEARCH > $LDAPSORTED

#echo ldapsorted
#cat $LDAPSORTED

#------ find the changed dns, which could be adds or deletes

diff <(awk -F\| '/dn/ {print $1}' $EL_SORTED) <(awk -F\| '/dn/ {print $1}' $LDAPSORTED) | grep "^[<>]" > $DIFFS1

#echo diffs1
#cat $DIFFS1

#----- straight deletes

# get the right side dn's from the dn diff file and turns these dn's into a ldif delete commands. Note that we 
# only need the dn to do a delete (not the full record)

echo '# straight deletes' > $LDIF

awk '/^>/ {print substr($0,3)}' $DIFFS1 | perl -pe "$REGEX_DN_TO_LDIF_DEL" >> $LDIF

#----- straight adds

# get the left side dn's from the dn diff file and get their full person record rom the left hand side file
# then turn these into ldif insert commands

echo '' >> $LDIF
echo '# straight adds' >> $LDIF

grep -f <(awk '/^</ {print substr($0,3)}' $DIFFS1) $EL_SORTED | perl -pe "$REGEX_PIPE_RECORD_TO_LDIF_INS" >> $LDIF

#---- modified records are deleted and added again 

# the sorted records are diffed and the dns already handled above are excluded. This leaves
# us with modified records only. In the case of deletes we only need the dn. In the case of ads
# we need the corresponding full record

echo '' >> $LDIF
echo '# modified records' >> $LDIF

# diff the changed records  | exclude processed  | get cn to delete and drop 2 chars    | turn cn into a ldif del
diff $EL_SORTED $LDAPSORTED | grep -v -f $DIFFS1 | awk -F\| '/^>/ {print substr($1,3)}' | perl -pe "$REGEX_DN_TO_LDIF_DEL" >> $LDIF

# diff the chagned records  | exclude processed  | get record to insert and drop 2 chars| turn record into an ldif insert
diff $EL_SORTED $LDAPSORTED | grep -v -f $DIFFS1 | awk '/^</ {print substr($0,3)}'      | perl -pe "$REGEX_PIPE_RECORD_TO_LDIF_INS" >> $LDIF


#---- if we have any command lines in our LDIF file then apply it

# grep returns 0 if it made a match or 1 if no match
grep -q ^[a-z] $LDIF
RC=$?

if [[ $RC > 0 ]]; then
  echo "no LDIF changes"
else
  echo "LDIF file to apply ------"
  cat $LDIF

  echo "LDIF start --------------"

  ldapmodify ${LDAP_MODIFY_PARAMS} -f $LDIF
  RC=$?
  if [[ $RC > 0 ]]; then
    echo non zero RC: $RC
    exit $RC
  fi

  echo "LDIF finished ----------"
fi

#----- cleanup
rm -r $TMPDIR
date
