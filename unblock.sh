#!/system/bin/sh
# Project: Root Network Unblocker & HTTP Proxy Enabler (JO/EG)
# Author: YourName

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# التحقق من صلاحيات الروت
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[!] خطأ: يجب تشغيل السكريبت بصلاحيات الروت (اكتب su أولاً).${NC}"
    exit 1
fi

start_bypass() {
    echo -e "${YELLOW}[*] جاري تفعيل نظام فك الحجب الشامل...${NC}"
    
    # 1. حجب تسرب IPv6 لإجبار الشبكة على استخدام النفق المشفر IPv4
    ip6tables -P OUTPUT DROP
    ip6tables -P INPUT DROP
    
    # 2. ضبط DNS المشفر على مستوى النظام (Cloudflare)
    settings put global private_dns_mode hostname
    settings put global private_dns_specifier one.one.one.one
    
    # 3. تعديل قيم TTL وحزم TCP لتجاوز الفحص العميق للحزم (DPI)
    iptables -t mangle -A POSTROUTING -j TTL --ttl-set 65
    
    # 4. التأكد من تفعيل نفق WARP أو WireGuard إذا كان مثبتاً
    if command -v wg-quick >/dev/null 2>&1 && [ -f /data/adb/warp.conf ]; then
        wg-quick up /data/adb/warp.conf >/dev/null 2>&1
        echo -e "${GREEN}[+] تم تشغيل نفق WARP المشفر بنجاح.${NC}"
    else
        echo -e "${YELLOW}[!] تنبيه: تأكد من تشغيل تطبيق 1.1.1.1 (WARP) في الخلفية لتغليف بروكسي HTTP.${NC}"
    fi

    # 5. خيار تشغيل بروكسي HTTP على كامل النظام (اختياري عبر المتغيرات)
    if [ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ]; then
        settings put global http_proxy "${PROXY_IP}:${PROXY_PORT}"
        echo -e "${GREEN}[+] تم تفعيل بروكسي HTTP (${PROXY_IP}:${PROXY_PORT}) على كامل الشبكة.${NC}"
    fi

    echo -e "${GREEN}[✔] تم فك الحجب بنجاح! يعمل الآن على الواي فاي والبيانات.${NC}"
}

stop_bypass() {
    echo -e "${YELLOW}[*] جاري إيقاف فك الحجب وإعادة الشبكة للوضع الطبيعي...${NC}"
    
    # 1. إعادة تفعيل IPv6
    ip6tables -P OUTPUT ACCEPT
    ip6tables -P INPUT ACCEPT
    
    # 2. إزالة بروكسي النظام
    settings put global http_proxy :0
    
    # 3. إعادة DNS للوضع التلقائي
    settings put global private_dns_mode opportunistic
    
    # 4. إيقاف نفق WireGuard إن وجد
    if command -v wg-quick >/dev/null 2>&1 && [ -f /data/adb/warp.conf ]; then
        wg-quick down /data/adb/warp.conf >/dev/null 2>&1
    fi

    echo -e "${RED}[✖] تم الإيقاف وعادت الشبكة إلى وضعها الافتراضي.${NC}"
}

case "$1" in
    start)
        start_bypass
        ;;
    stop)
        stop_bypass
        ;;
    *)
        echo -e "الاستخدام الصحيح للأداة:"
        echo -e "  لتشغيل فك الحجب:  ${GREEN}su -c 'sh unblock.sh start'${NC}"
        echo -e "  لإيقاف فك الحجب:  ${RED}su -c 'sh unblock.sh stop'${NC}"
        echo -e "  للتشغيل مع بروكسي: ${YELLOW}su -c 'PROXY_IP=1.2.3.4 PROXY_PORT=8080 sh unblock.sh start'${NC}"
        ;;
esac
