#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

ipv6=true

source ./hsr_common.sh

optstring="h4"
usage() {
	echo "Usage: $0 [OPTION]"
	echo -e "\t-4: IPv4 only: disable IPv6 tests (default: test both IPv4 and IPv6)"
}

while getopts "$optstring" option;do
	case "$option" in
	"h")
		usage $0
		exit 0
		;;
	"4")
		ipv6=false
		;;
	"?")
		usage $0
		exit 1
		;;
esac
done

do_complete_ping_test()
{
	echo "INFO: Initial validation ping."
	# Each node has to be able each one.
	do_ping "$ns1" 100.64.0.2
	do_ping "$ns2" 100.64.0.1
	do_ping "$ns3" 100.64.0.1
	stop_if_error "Initial validation failed."

	do_ping "$ns1" 100.64.0.3
	do_ping "$ns2" 100.64.0.3
	do_ping "$ns3" 100.64.0.2

	do_ping "$ns1" dead:beef:1::2
	do_ping "$ns1" dead:beef:1::3
	do_ping "$ns2" dead:beef:1::1
	do_ping "$ns2" dead:beef:1::2
	do_ping "$ns3" dead:beef:1::1
	do_ping "$ns3" dead:beef:1::2

	stop_if_error "Initial validation failed."

# Wait until supervisor all supervision frames have been processed and the node
# entries have been merged. Otherwise duplicate frames will be observed which is
# valid at this stage.
	WAIT=5
	while [ ${WAIT} -gt 0 ]
	do
		grep 00:00:00:00:00:00 /sys/kernel/debug/hsr/hsr*/node_table
		if [ $? -ne 0 ]
		then
			break
		fi
		sleep 1
		let "WAIT = WAIT - 1"
	done

# Just a safety delay in case the above check didn't handle it.
	sleep 1

	echo "INFO: Longer ping test."
	do_ping_long "$ns1" 100.64.0.2
	do_ping_long "$ns1" dead:beef:1::2
	do_ping_long "$ns1" 100.64.0.3
	do_ping_long "$ns1" dead:beef:1::3

	stop_if_error "Longer ping test failed."

	do_ping_long "$ns2" 100.64.0.1
	do_ping_long "$ns2" dead:beef:1::1
	do_ping_long "$ns2" 100.64.0.3
	do_ping_long "$ns2" dead:beef:1::2
	stop_if_error "Longer ping test failed."

	do_ping_long "$ns3" 100.64.0.1
	do_ping_long "$ns3" dead:beef:1::1
	do_ping_long "$ns3" 100.64.0.2
	do_ping_long "$ns3" dead:beef:1::2
	stop_if_error "Longer ping test failed."

	echo "INFO: Cutting one link."
	do_ping_long "$ns1" 100.64.0.3 &

	sleep 3
	ip -net "$ns3" link set ns3eth1 down
	wait

	ip -net "$ns3" link set ns3eth1 up

	stop_if_error "Failed with one link down."

	echo "INFO: Delay the link and drop a few packages."
	tc -net "$ns3" qdisc add dev ns3eth1 root netem delay 50ms
	tc -net "$ns2" qdisc add dev ns2eth1 root netem delay 5ms loss 25%

	do_ping_long "$ns1" 100.64.0.2
	do_ping_long "$ns1" 100.64.0.3

	stop_if_error "Failed with delay and packetloss."

	do_ping_long "$ns2" 100.64.0.1
	do_ping_long "$ns2" 100.64.0.3

	stop_if_error "Failed with delay and packetloss."

	do_ping_long "$ns3" 100.64.0.1
	do_ping_long "$ns3" 100.64.0.2
	stop_if_error "Failed with delay and packetloss."

	echo "INFO: All good."
}

setup_hsr_interfaces()
{
	local HSRv="$1"

	echo "INFO: preparing interfaces for HSRv${HSRv}."
# Three HSR nodes. Each node has one link to each of its neighbour, two links in total.
#
#    ns1eth1 ----- ns2eth1
#      hsr1         hsr2
#    ns1eth2       ns2eth2
#       |            |
#    ns3eth1      ns3eth2
#           \    /
#            hsr3
#
	# Interfaces
	ip link add ns1eth1 netns "$ns1" type veth peer name ns2eth1 netns "$ns2"
	ip link add ns1eth2 netns "$ns1" type veth peer name ns3eth1 netns "$ns3"
	ip link add ns3eth2 netns "$ns3" type veth peer name ns2eth2 netns "$ns2"

	# HSRv0/1
	ip -net "$ns1" link add name hsr1 type hsr slave1 ns1eth1 slave2 ns1eth2 supervision 45 version $HSRv proto 0
	ip -net "$ns2" link add name hsr2 type hsr slave1 ns2eth1 slave2 ns2eth2 supervision 45 version $HSRv proto 0
	ip -net "$ns3" link add name hsr3 type hsr slave1 ns3eth1 slave2 ns3eth2 supervision 45 version $HSRv proto 0

	# IP for HSR
	ip -net "$ns1" addr add 100.64.0.1/24 dev hsr1
	ip -net "$ns1" addr add dead:beef:1::1/64 dev hsr1 nodad
	ip -net "$ns2" addr add 100.64.0.2/24 dev hsr2
	ip -net "$ns2" addr add dead:beef:1::2/64 dev hsr2 nodad
	ip -net "$ns3" addr add 100.64.0.3/24 dev hsr3
	ip -net "$ns3" addr add dead:beef:1::3/64 dev hsr3 nodad

	ip -net "$ns1" link set address 00:11:22:00:01:01 dev ns1eth1
	ip -net "$ns1" link set address 00:11:22:00:01:02 dev ns1eth2

	ip -net "$ns2" link set address 00:11:22:00:02:01 dev ns2eth1
	ip -net "$ns2" link set address 00:11:22:00:02:02 dev ns2eth2

	ip -net "$ns3" link set address 00:11:22:00:03:01 dev ns3eth1
	ip -net "$ns3" link set address 00:11:22:00:03:02 dev ns3eth2

	# All Links up
	ip -net "$ns1" link set ns1eth1 up
	ip -net "$ns1" link set ns1eth2 up
	ip -net "$ns1" link set hsr1 up

	ip -net "$ns2" link set ns2eth1 up
	ip -net "$ns2" link set ns2eth2 up
	ip -net "$ns2" link set hsr2 up

	ip -net "$ns3" link set ns3eth1 up
	ip -net "$ns3" link set ns3eth2 up
	ip -net "$ns3" link set hsr3 up
}

setup_vlan_interfaces() {
	ip -net "$ns1" link add link hsr1 name hsr1.2 type vlan id 2
	ip -net "$ns1" link add link hsr1 name hsr1.3 type vlan id 3
	ip -net "$ns1" link add link hsr1 name hsr1.4 type vlan id 4
	ip -net "$ns1" link add link hsr1 name hsr1.5 type vlan id 5

	ip -net "$ns2" link add link hsr2 name hsr2.2 type vlan id 2
	ip -net "$ns2" link add link hsr2 name hsr2.3 type vlan id 3
	ip -net "$ns2" link add link hsr2 name hsr2.4 type vlan id 4
	ip -net "$ns2" link add link hsr2 name hsr2.5 type vlan id 5

	ip -net "$ns3" link add link hsr3 name hsr3.2 type vlan id 2
	ip -net "$ns3" link add link hsr3 name hsr3.3 type vlan id 3
	ip -net "$ns3" link add link hsr3 name hsr3.4 type vlan id 4
	ip -net "$ns3" link add link hsr3 name hsr3.5 type vlan id 5

	ip -net "$ns1" addr add 100.64.2.1/24 dev hsr1.2
	ip -net "$ns1" addr add 100.64.3.1/24 dev hsr1.3
	ip -net "$ns1" addr add 100.64.4.1/24 dev hsr1.4
	ip -net "$ns1" addr add 100.64.5.1/24 dev hsr1.5

	ip -net "$ns2" addr add 100.64.2.2/24 dev hsr2.2
	ip -net "$ns2" addr add 100.64.3.2/24 dev hsr2.3
	ip -net "$ns2" addr add 100.64.4.2/24 dev hsr2.4
	ip -net "$ns2" addr add 100.64.5.2/24 dev hsr2.5

	ip -net "$ns3" addr add 100.64.2.3/24 dev hsr3.2
	ip -net "$ns3" addr add 100.64.3.3/24 dev hsr3.3
	ip -net "$ns3" addr add 100.64.4.3/24 dev hsr3.4
	ip -net "$ns3" addr add 100.64.5.3/24 dev hsr3.5

	ip -net "$ns1" link set dev hsr1.2 up
	ip -net "$ns1" link set dev hsr1.3 up
	ip -net "$ns1" link set dev hsr1.4 up
	ip -net "$ns1" link set dev hsr1.5 up

	ip -net "$ns2" link set dev hsr2.2 up
	ip -net "$ns2" link set dev hsr2.3 up
	ip -net "$ns2" link set dev hsr2.4 up
	ip -net "$ns2" link set dev hsr2.5 up

	ip -net "$ns3" link set dev hsr3.2 up
	ip -net "$ns3" link set dev hsr3.3 up
	ip -net "$ns3" link set dev hsr3.4 up
	ip -net "$ns3" link set dev hsr3.5 up

}

hsr_vlan_ping() {
	do_ping "$ns1" 100.64.2.2
	do_ping "$ns1" 100.64.3.2
	do_ping "$ns1" 100.64.4.2
	do_ping "$ns1" 100.64.5.2

	do_ping "$ns1" 100.64.2.3
	do_ping "$ns1" 100.64.3.3
	do_ping "$ns1" 100.64.4.3
	do_ping "$ns1" 100.64.5.3

	do_ping "$ns2" 100.64.2.1
	do_ping "$ns2" 100.64.3.1
	do_ping "$ns2" 100.64.4.1
	do_ping "$ns2" 100.64.5.1

	do_ping "$ns2" 100.64.2.3
	do_ping "$ns2" 100.64.3.3
	do_ping "$ns2" 100.64.4.3
	do_ping "$ns2" 100.64.5.3

	do_ping "$ns3" 100.64.2.1
	do_ping "$ns3" 100.64.3.1
	do_ping "$ns3" 100.64.4.1
	do_ping "$ns3" 100.64.5.1

	do_ping "$ns3" 100.64.2.2
	do_ping "$ns3" 100.64.3.2
	do_ping "$ns3" 100.64.4.2
	do_ping "$ns3" 100.64.5.2
}

run_vlan_tests() {
	vlan_challenged_hsr1=$(ip net exec "$ns1" ethtool -k hsr1 | grep "vlan-challenged" | awk '{print $2}')
	vlan_challenged_hsr2=$(ip net exec "$ns2" ethtool -k hsr2 | grep "vlan-challenged" | awk '{print $2}')
	vlan_challenged_hsr3=$(ip net exec "$ns3" ethtool -k hsr3 | grep "vlan-challenged" | awk '{print $2}')

	if [[ "$vlan_challenged_hsr1" = "off" || "$vlan_challenged_hsr2" = "off" || "$vlan_challenged_hsr3" = "off" ]]; then
		echo "INFO: Running VLAN tests"
		setup_vlan_interfaces
		hsr_vlan_ping
	else
		echo "INFO: Not Running VLAN tests as the device does not support VLAN"
	fi
}

check_prerequisites
setup_ns ns1 ns2 ns3

trap cleanup_all_ns EXIT

setup_hsr_interfaces 0
do_complete_ping_test

run_vlan_tests

setup_ns ns1 ns2 ns3

setup_hsr_interfaces 1
do_complete_ping_test

run_vlan_tests

exit $ret
