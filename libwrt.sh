rm -rf package/emortal/luci-app-athena-led
git clone --depth=1 https://github.com/NONGFAH/luci-app-athena-led package/luci-app-athena-led
chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led

# 删除或注释掉安装 etc/config/openvpn 的语句
sed -i '/etc\/config\/openvpn/d' feeds/luci/applications/luci-app-openvpn-server/Makefile
