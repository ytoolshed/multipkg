if ! grep svscanboot /etc/inittab 2>&1 > /dev/null ; then
    echo SV1:23:respawn:/usr/local/bin/svscanboot >>/etc/inittab
    init q
fi
