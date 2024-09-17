#!/bin/bash

echo "*************"
echo " Argon Setup  "
echo "*************"


# Check time if need to 'fix'
NEEDSTIMESYNC=0
LOCALTIME=$(date -u +%s%N | cut -b1-10)
GLOBALTIME=$(curl -s 'http://worldtimeapi.org/api/ip.txt' | grep unixtime | cut -b11-20)
TIMEDIFF=$((GLOBALTIME-LOCALTIME))

# about 26hrs, max timezone difference
if [ $TIMEDIFF -gt 100000 ]
then
	NEEDSTIMESYNC=1
fi


argon_time_error() {
	echo "**********************************************"
	echo "* WARNING: Device time seems to be incorrect *"
	echo "* This may cause problems during setup.      *"
	echo "**********************************************"
	echo "Possible Network Time Protocol Server issue"
	echo "Try running the following to correct:"
    echo " curl -k https://download.argon40.com/tools/setntpserver.sh | bash"
}

if [ $NEEDSTIMESYNC -eq 1 ]
then
	argon_time_error
fi


# Helper variables
ARGONDOWNLOADSERVER=https://download.argon40.com

INSTALLATIONFOLDER=/etc/argon

FLAGFILEV1=$INSTALLATIONFOLDER/flag_v1

versioninfoscript=$INSTALLATIONFOLDER/argon-versioninfo.sh

uninstallscript=$INSTALLATIONFOLDER/argon-uninstall.sh
shutdownscript=/lib/systemd/system-shutdown/argon-shutdown.sh
configscript=$INSTALLATIONFOLDER/argon-config
unitconfigscript=$INSTALLATIONFOLDER/argon-unitconfig.sh
blstrdacconfigscript=$INSTALLATIONFOLDER/argon-blstrdac.sh
statusdisplayscript=$INSTALLATIONFOLDER/argon-status.sh

setupmode="Setup"

if [ -f $configscript ]
then
	setupmode="Update"
	echo "Updating files"
else
	 mkdir $INSTALLATIONFOLDER
	 chmod 755 $INSTALLATIONFOLDER
fi

##########
# Start code lifted from raspi-config
# is_pifive, get_serial_hw and do_serial_hw based on raspi-config

if [ -e /boot/firmware/config.txt ] ; then
  FIRMWARE=/firmware
else
  FIRMWARE=
fi
CONFIG=/boot${FIRMWARE}/config.txt
TMPCONFIG=/dev/shm/argontmp.bak

set_config_var() {
    if ! grep -q -E "$1=$2" $3 ; then
      echo "$1=$2" |  tee -a $3 > /dev/null
    fi
}

is_pifive() {
  grep -q "^Revision\s*:\s*[ 123][0-9a-fA-F][0-9a-fA-F]4[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$" /proc/cpuinfo
  return $?
}


get_serial_hw() {
  if is_pifive ; then
    if grep -q -E "dtparam=uart0=off" $CONFIG ; then
      echo 1
    elif grep -q -E "dtparam=uart0" $CONFIG ; then
      echo 0
    else
      echo 1
    fi
  else
    if grep -q -E "^enable_uart=1" $CONFIG ; then
      echo 0
    elif grep -q -E "^enable_uart=0" $CONFIG ; then
      echo 1
    elif [ -e /dev/serial0 ] ; then
      echo 0
    else
      echo 1
    fi
  fi
}

do_serial_hw() {
  if [ $1 -eq 0 ] ; then
    if is_pifive ; then
      set_config_var dtparam=uart0 on $CONFIG
    else
      set_config_var enable_uart 1 $CONFIG
    fi
  else
    if is_pifive ; then
       sed $CONFIG -i -e "/dtparam=uart0.*/d"
    else
      set_config_var enable_uart 0 $CONFIG
    fi
  fi
}

# End code lifted from raspi-config
##########

# Reuse is_pifive, set_config_var
set_nvme_default() {
  if is_pifive ; then
    set_config_var dtparam nvme $CONFIG
    set_config_var dtparam=pciex1_gen 3 $CONFIG
  fi
}
set_maxusbcurrent() {
  if is_pifive ; then
    set_config_var max_usb_current 1 $CONFIG
  fi
}


argon_check_pkg() {
    RESULT=$(dpkg-query -W -f='${Status}\n' "$1" 2> /dev/null | grep "installed")

    if [ "" == "$RESULT" ]; then
        echo "NG"
    else
        echo "OK"
    fi
}


CHECKDEVICE="one"	# Hardcoded for argonone
# Check if has RTC
# Todo for multiple OS

#i2cdetect -y 1 | grep -q ' 51 '
#if [ $? -eq 0 ]
#then
#        CHECKDEVICE="eon"
#fi

CHECKGPIOMODE="libgpiod" # libgpiod or rpigpio

# Check if Raspbian, Ubuntu, others
CHECKPLATFORM="Others"
CHECKPLATFORMVERSION=""
CHECKPLATFORMVERSIONNUM=""
if [ -f "/etc/os-release" ]
then
	source /etc/os-release
	if [ "$ID" = "raspbian" ]
	then
		CHECKPLATFORM="Raspbian"
		CHECKPLATFORMVERSION=$VERSION_ID
	elif [ "$ID" = "debian" ]
	then
		# For backwards compatibility, continue using raspbian
		CHECKPLATFORM="Raspbian"
		CHECKPLATFORMVERSION=$VERSION_ID
	elif [ "$ID" = "ubuntu" ]
	then
		CHECKPLATFORM="Ubuntu"
		CHECKPLATFORMVERSION=$VERSION_ID
	fi
	echo ${CHECKPLATFORMVERSION} | grep -e "\." > /dev/null
	if [ $? -eq 0 ]
	then
		CHECKPLATFORMVERSIONNUM=`cut -d "." -f2 <<< $CHECKPLATFORMVERSION `
		CHECKPLATFORMVERSION=`cut -d "." -f1 <<< $CHECKPLATFORMVERSION `
	fi
fi

gpiopkg="python3-libgpiod"
if [ "$CHECKGPIOMODE" = "rpigpio" ]
then
	if [ "$CHECKPLATFORM" = "Raspbian" ]
	then
		gpiopkg="raspi-gpio python3-rpi.gpio"
	else
		gpiopkg="python3-rpi.gpio"
	fi
fi

if [ "$CHECKPLATFORM" = "Raspbian" ]
then
	if [ "$CHECKDEVICE" = "eon" ]
	then
		pkglist=($gpiopkg python3-smbus i2c-tools smartmontools)
	else
		pkglist=($gpiopkg python3-smbus i2c-tools)
	fi
else
	# Todo handle lgpio
	# Ubuntu has serial and i2c enabled
	if [ "$CHECKDEVICE" = "eon" ]
	then
		pkglist=($gpiopkg python3-smbus i2c-tools smartmontools)
	else
		pkglist=($gpiopkg python3-smbus i2c-tools)
	fi
fi

for curpkg in ${pkglist[@]}; do
	 apt-get install -y $curpkg
	RESULT=$(argon_check_pkg "$curpkg")
	if [ "NG" == "$RESULT" ]
	then
		echo "********************************************************************"
		echo "Please also connect device to the internet and restart installation."
		echo "********************************************************************"
		exit
	fi
done

# Ubuntu Mate for RPi has raspi-config too
command -v raspi-config &> /dev/null
if [ $? -eq 0 ]
then
	# Enable i2c and serial
	 raspi-config nonint do_i2c 0
	if [ ! "$CHECKDEVICE" = "fanhat" ]
	then

		if [ "$CHECKPLATFORM" = "Raspbian" ]
		then
			# bookworm raspi-config prompts user when configuring serial
			if [ $(get_serial_hw) -eq 1 ]; then
				do_serial_hw 0
			fi
		else
			 raspi-config nonint do_serial 2
		fi
	fi
fi

# Added to enabled NVMe for pi5
set_nvme_default

# Fan Setup
basename="argonone"
daemonname=$basename"d"
irconfigscript=$INSTALLATIONFOLDER/${basename}-ir
fanconfigscript=$INSTALLATIONFOLDER/${basename}-fanconfig.sh
eepromrpiscript="/usr/bin/rpi-eeprom-config"
eepromconfigscript=$INSTALLATIONFOLDER/${basename}-eepromconfig.py
powerbuttonscript=$INSTALLATIONFOLDER/$daemonname.py
unitconfigfile=/etc/argonunits.conf
daemonconfigfile=/etc/$daemonname.conf
daemonfanservice=/lib/systemd/system/$daemonname.service

daemonhddconfigfile=/etc/${daemonname}-hdd.conf


if [ -f "$eepromrpiscript" ]
then
	# EEPROM Config Script
	 wget $ARGONDOWNLOADSERVER/scripts/argon-rpi-eeprom-config-psu.py -O $eepromconfigscript --quiet
	 chmod 755 $eepromconfigscript
fi

# Fan Config Script
 wget $ARGONDOWNLOADSERVER/scripts/argonone-fanconfig.sh -O $fanconfigscript --quiet
 chmod 755 $fanconfigscript


# Fan Daemon/Service Files
 wget $ARGONDOWNLOADSERVER/scripts/argononed.py -O $powerbuttonscript --quiet
 wget $ARGONDOWNLOADSERVER/scripts/argononed.service -O $daemonfanservice --quiet
 chmod 644 $daemonfanservice

if [ ! "$CHECKDEVICE" = "fanhat" ]
then
	# IR Files
	 wget $ARGONDOWNLOADSERVER/scripts/argonone-irconfig.sh -O $irconfigscript --quiet
	 chmod 755 $irconfigscript

	if [ ! "$CHECKDEVICE" = "eon" ]
	then
		 wget $ARGONDOWNLOADSERVER/scripts/argon-blstrdac.sh -O $blstrdacconfigscript --quiet
		 chmod 755 $blstrdacconfigscript
	fi
fi

# Other utility scripts
 wget $ARGONDOWNLOADSERVER/scripts/argonstatus.py -O $INSTALLATIONFOLDER/argonstatus.py --quiet
 wget $ARGONDOWNLOADSERVER/scripts/argon-status.sh -O $statusdisplayscript --quiet
 chmod 755 $statusdisplayscript


 wget $ARGONDOWNLOADSERVER/scripts/argon-versioninfo.sh -O $versioninfoscript --quiet
 chmod 755 $versioninfoscript

 wget $ARGONDOWNLOADSERVER/scripts/argonsysinfo.py -O $INSTALLATIONFOLDER/argonsysinfo.py --quiet

if [ -f "$FLAGFILEV1" ]
then
	 wget $ARGONDOWNLOADSERVER/scripts/argonregister-v1.py -O $INSTALLATIONFOLDER/argonregister.py --quiet
else
	 wget $ARGONDOWNLOADSERVER/scripts/argonregister.py -O $INSTALLATIONFOLDER/argonregister.py --quiet
fi

 wget "$ARGONDOWNLOADSERVER/scripts/argonpowerbutton-${CHECKGPIOMODE}.py" -O $INSTALLATIONFOLDER/argonpowerbutton.py --quiet

 wget $ARGONDOWNLOADSERVER/scripts/argononed.py -O $powerbuttonscript --quiet

 wget $ARGONDOWNLOADSERVER/scripts/argon-unitconfig.sh -O $unitconfigscript --quiet
 chmod 755 $unitconfigscript


# Generate default Fan config file if non-existent
if [ ! -f $daemonconfigfile ]; then
	 touch $daemonconfigfile
	 chmod 666 $daemonconfigfile

	echo '#' >> $daemonconfigfile
	echo '# Argon Fan Speed Configuration (CPU)' >> $daemonconfigfile
	echo '#' >> $daemonconfigfile
	echo '55=30' >> $daemonconfigfile
	echo '60=55' >> $daemonconfigfile
	echo '65=100' >> $daemonconfigfile
fi

if [ "$CHECKDEVICE" = "eon" ]
then
	if [ ! -f $daemonhddconfigfile ]; then
		 touch $daemonhddconfigfile
		 chmod 666 $daemonhddconfigfile

		echo '#' >> $daemonhddconfigfile
		echo '# Argon Fan Speed Configuration (HDD)' >> $daemonhddconfigfile
		echo '#' >> $daemonhddconfigfile
		echo '35=30' >> $daemonhddconfigfile
		echo '40=55' >> $daemonhddconfigfile
		echo '45=100' >> $daemonhddconfigfile
	fi
fi

# Generate default Unit config file if non-existent
if [ ! -f $unitconfigfile ]; then
	 touch $unitconfigfile
	 chmod 666 $unitconfigfile

	echo '#' >> $unitconfigfile
fi


if [ "$CHECKDEVICE" = "eon" ]
then
	# RTC Setup
	basename="argoneon"
	daemonname=$basename"d"

	rtcconfigfile=/etc/argoneonrtc.conf
	rtcconfigscript=$INSTALLATIONFOLDER/${basename}-rtcconfig.sh
	daemonrtcservice=/lib/systemd/system/$daemonname.service
	rtcdaemonscript=$INSTALLATIONFOLDER/$daemonname.py

	oledconfigscript=$INSTALLATIONFOLDER/${basename}-oledconfig.sh
	oledlibscript=$INSTALLATIONFOLDER/${basename}oled.py
	oledconfigfile=/etc/argoneonoled.conf

	# Generate default RTC config file if non-existent
	if [ ! -f $rtcconfigfile ]; then
		 touch $rtcconfigfile
		 chmod 666 $rtcconfigfile

		echo '#' >> $rtcconfigfile
		echo '# Argon RTC Configuration' >> $rtcconfigfile
		echo '#' >> $rtcconfigfile
	fi
	# Generate default OLED config file if non-existent
	if [ ! -f $oledconfigfile ]; then
		 touch $oledconfigfile
		 chmod 666 $oledconfigfile

		echo '#' >> $oledconfigfile
		echo '# Argon OLED Configuration' >> $oledconfigfile
		echo '#' >> $oledconfigfile
		echo 'switchduration=30' >> $oledconfigfile
		echo 'screenlist="clock cpu storage raid ram temp ip"' >> $oledconfigfile
	fi


	# RTC Config Script
	 wget $ARGONDOWNLOADSERVER/scripts/argoneon-rtcconfig.sh -O $rtcconfigscript --quiet
	 chmod 755 $rtcconfigscript

	# RTC Daemon/Service Files
	 wget $ARGONDOWNLOADSERVER/scripts/argoneond.py -O $rtcdaemonscript --quiet
	 wget $ARGONDOWNLOADSERVER/scripts/argoneond.service -O $daemonrtcservice --quiet
	 wget $ARGONDOWNLOADSERVER/scripts/argoneonoled.py -O $oledlibscript --quiet
	 chmod 644 $daemonrtcservice

	# OLED Config Script
	 wget $ARGONDOWNLOADSERVER/scripts/argoneon-oledconfig.sh -O $oledconfigscript --quiet
	 chmod 755 $oledconfigscript


	if [ ! -d $INSTALLATIONFOLDER/oled ]
	then
		 mkdir $INSTALLATIONFOLDER/oled
	fi

	for binfile in font8x6 font16x12 font32x24 font64x48 font16x8 font24x16 font48x32 bgdefault bgram bgip bgtemp bgcpu bgraid bgstorage bgtime
	do
		 wget $ARGONDOWNLOADSERVER/oled/${binfile}.bin -O $INSTALLATIONFOLDER/oled/${binfile}.bin --quiet
	done
fi


# Argon Uninstall Script
 wget $ARGONDOWNLOADSERVER/scripts/argon-uninstall.sh -O $uninstallscript --quiet
 chmod 755 $uninstallscript

# Argon Shutdown script
 wget $ARGONDOWNLOADSERVER/scripts/argon-shutdown.sh -O $shutdownscript --quiet
 chmod 755 $shutdownscript

# Argon Config Script
if [ -f $configscript ]; then
	 rm $configscript
fi
 touch $configscript

# To ensure we can write the following lines
 chmod 666 $configscript

echo '#!/bin/bash' >> $configscript

echo 'echo "--------------------------"' >> $configscript
echo 'echo "Argon Configuration Tool"' >> $configscript
echo "$versioninfoscript simple" >> $configscript
echo 'echo "--------------------------"' >> $configscript

echo 'get_number () {' >> $configscript
echo '	read curnumber' >> $configscript
echo '	if [ -z "$curnumber" ]' >> $configscript
echo '	then' >> $configscript
echo '		echo "-2"' >> $configscript
echo '		return' >> $configscript
echo '	elif [[ $curnumber =~ ^[+-]?[0-9]+$ ]]' >> $configscript
echo '	then' >> $configscript
echo '		if [ $curnumber -lt 0 ]' >> $configscript
echo '		then' >> $configscript
echo '			echo "-1"' >> $configscript
echo '			return' >> $configscript
echo '		elif [ $curnumber -gt 100 ]' >> $configscript
echo '		then' >> $configscript
echo '			echo "-1"' >> $configscript
echo '			return' >> $configscript
echo '		fi	' >> $configscript
echo '		echo $curnumber' >> $configscript
echo '		return' >> $configscript
echo '	fi' >> $configscript
echo '	echo "-1"' >> $configscript
echo '	return' >> $configscript
echo '}' >> $configscript
echo '' >> $configscript

echo 'mainloopflag=1' >> $configscript
echo 'while [ $mainloopflag -eq 1 ]' >> $configscript
echo 'do' >> $configscript
echo '	echo' >> $configscript
echo '	echo "Choose Option:"' >> $configscript
echo '	echo "  1. Configure Fan"' >> $configscript

blstrdacoption=0

if [ "$CHECKDEVICE" = "fanhat" ]
then
	uninstalloption="4"
else
	echo '	echo "  2. Configure IR"' >> $configscript
	if [ "$CHECKDEVICE" = "eon" ]
	then
		# ArgonEON Has RTC
		echo '	echo "  3. Configure RTC and/or Schedule"' >> $configscript
		echo '	echo "  4. Configure OLED"' >> $configscript
		uninstalloption="7"
	else
		uninstalloption="6"
		blstrdacoption=$(($uninstalloption-3))
		echo "	echo \"  $blstrdacoption. Configure BLSTR DAC (v3 only)\"" >> $configscript
	fi
fi

unitsoption=$(($uninstalloption-2))
echo "	echo \"  $unitsoption. Configure Units\"" >> $configscript
statusoption=$(($uninstalloption-1))
echo "	echo \"  $statusoption. System Information\"" >> $configscript

echo "	echo \"  $uninstalloption. Uninstall\"" >> $configscript
echo '	echo ""' >> $configscript
echo '	echo "  0. Exit"' >> $configscript
echo "	echo -n \"Enter Number (0-$uninstalloption):\"" >> $configscript
echo '	newmode=$( get_number )' >> $configscript


echo '	if [ $newmode -eq 0 ]' >> $configscript
echo '	then' >> $configscript
echo '		echo "Thank you."' >> $configscript
echo '		mainloopflag=0' >> $configscript
echo '	elif [ $newmode -eq 1 ]' >> $configscript
echo '	then' >> $configscript

if [ "$CHECKDEVICE" = "eon" ]
then
	echo '		echo "Choose Triggers:"' >> $configscript
	echo '		echo "  1. CPU Temperature"' >> $configscript
	echo '		echo "  2. HDD Temperature"' >> $configscript
	echo '		echo ""' >> $configscript
	echo '		echo "  0. Cancel"' >> $configscript
	echo "		echo -n \"Enter Number (0-2):\"" >> $configscript
	echo '		submode=$( get_number )' >> $configscript

	echo '		if [ $submode -eq 1 ]' >> $configscript
	echo '		then' >> $configscript
	echo "			$fanconfigscript" >> $configscript
	echo '			mainloopflag=0' >> $configscript
	echo '		elif [ $submode -eq 2 ]' >> $configscript
	echo '		then' >> $configscript
	echo "			$fanconfigscript hdd" >> $configscript
	echo '			mainloopflag=0' >> $configscript
	echo '		fi' >> $configscript

else
	echo "		$fanconfigscript" >> $configscript
	echo '		mainloopflag=0' >> $configscript
fi

if [ ! "$CHECKDEVICE" = "fanhat" ]
then
	echo '	elif [ $newmode -eq 2 ]' >> $configscript
	echo '	then' >> $configscript
	echo "		$irconfigscript" >> $configscript
	echo '		mainloopflag=0' >> $configscript

	if [ "$CHECKDEVICE" = "eon" ]
	then
		echo '	elif [ $newmode -eq 3 ]' >> $configscript
		echo '	then' >> $configscript
		echo "		$rtcconfigscript" >> $configscript
		echo '		mainloopflag=0' >> $configscript
		echo '	elif [ $newmode -eq 4 ]' >> $configscript
		echo '	then' >> $configscript
		echo "		$oledconfigscript" >> $configscript
		echo '		mainloopflag=0' >> $configscript
	fi

	if [ $blstrdacoption -gt 0 ]
	then
		echo "	elif [ \$newmode -eq $blstrdacoption ]" >> $configscript
		echo '	then' >> $configscript
		echo "		$blstrdacconfigscript" >> $configscript
		echo '		mainloopflag=0' >> $configscript
	fi
fi

echo "	elif [ \$newmode -eq $unitsoption ]" >> $configscript
echo '	then' >> $configscript
echo "		$unitconfigscript" >> $configscript
echo '		mainloopflag=0' >> $configscript

echo "	elif [ \$newmode -eq $statusoption ]" >> $configscript
echo '	then' >> $configscript
echo "		$statusdisplayscript" >> $configscript

echo "	elif [ \$newmode -eq $uninstalloption ]" >> $configscript
echo '	then' >> $configscript
echo "		$uninstallscript" >> $configscript
echo '		mainloopflag=0' >> $configscript
echo '	fi' >> $configscript
echo 'done' >> $configscript

 chmod 755 $configscript

# Desktop Icon
shortcutfile="/home/pi/Desktop/argonone-config.desktop"
if [ "$CHECKPLATFORM" = "Raspbian" ] && [ -d "/home/pi/Desktop" ]
then
	terminalcmd="lxterminal --working-directory=/home/pi/ -t"
	if  [ -f "/home/pi/.twisteros.twid" ]
	then
		terminalcmd="xfce4-terminal --default-working-directory=/home/pi/ -T"
	fi
	imagefile=ar1config.png
	if [ "$CHECKDEVICE" = "eon" ]
	then
		imagefile=argoneon.png
	fi
	 wget http://download.argon40.com/$imagefile -O /usr/share/pixmaps/$imagefile --quiet
	if [ -f $shortcutfile ]; then
		 rm $shortcutfile
	fi

	# Create Shortcuts
	echo "[Desktop Entry]" > $shortcutfile
	echo "Name=Argon Configuration" >> $shortcutfile
	echo "Comment=Argon Configuration" >> $shortcutfile
	echo "Icon=/usr/share/pixmaps/$imagefile" >> $shortcutfile
	echo 'Exec='$terminalcmd' "Argon Configuration" -e '$configscript >> $shortcutfile
	echo "Type=Application" >> $shortcutfile
	echo "Encoding=UTF-8" >> $shortcutfile
	echo "Terminal=false" >> $shortcutfile
	echo "Categories=None;" >> $shortcutfile
	chmod 755 $shortcutfile
fi

configcmd="$(basename -- $configscript)"

if [ "$setupmode" = "Setup" ]
then
	if [ -f "/usr/bin/$configcmd" ]
	then
		 rm /usr/bin/$configcmd
	fi
	 ln -s $configscript /usr/bin/$configcmd

	if [ "$CHECKDEVICE" = "one" ]
	then
		 ln -s $configscript /usr/bin/argonone-config
		 ln -s $uninstallscript /usr/bin/argonone-uninstall
		 ln -s $irconfigscript /usr/bin/argonone-ir
	elif [ "$CHECKDEVICE" = "fanhat" ]
	then
		 ln -s $configscript /usr/bin/argonone-config
		 ln -s $uninstallscript /usr/bin/argonone-uninstall
	fi

	# Enable and Start Service(s)
	 systemctl daemon-reload
	 systemctl enable argononed.service
	 systemctl start argononed.service
	if [ "$CHECKDEVICE" = "eon" ]
	then
		 systemctl enable argoneond.service
		 systemctl start argoneond.service
	fi
else
	 systemctl daemon-reload
	 systemctl restart argononed.service
	if [ "$CHECKDEVICE" = "eon" ]
	then
		 systemctl restart argoneond.service
	fi
fi

if [ "$CHECKPLATFORM" = "Raspbian" ]
then
	if [ -f "$eepromrpiscript" ]
	then
		 apt-get update &&  apt-get upgrade -y
		 rpi-eeprom-update
		# EEPROM Config Script
		 $eepromconfigscript
	fi
else
	echo "WARNING: EEPROM not updated.  Please run this under Raspberry Pi OS"
fi

set_maxusbcurrent


echo "*********************"
echo "  $setupmode Completed "
echo "*********************"
$versioninfoscript
echo
echo "Use '$configcmd' to configure device"
echo



if [ $NEEDSTIMESYNC -eq 1 ]
then
	argon_time_error
fi

