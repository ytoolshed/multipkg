if [ $1 = 0 ] ; then
    grep -q svscanboot /etc/inittab || exit 0
    mv -f /etc/inittab /etc/inittab.tmp.$$
    sed /svscanboot/d </etc/inittab.tmp.$$ >/etc/inittab && rm /etc/inittab.tmp.$$
fi
init q
