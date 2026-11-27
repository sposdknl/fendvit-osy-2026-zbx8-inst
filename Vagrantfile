IMAGE_NAME = "bento/debian-13"

Vagrant.configure("2") do |config|
    config.ssh.insert_key = false

    config.vm.provider "virtualbox" do |v|
        v.name = "zbx8-fendvit"
        v.memory = 2048
        v.cpus = 2
    end

    config.vm.define "debian" do |debian|
        debian.vm.box = IMAGE_NAME
        debian.vm.hostname = "zbx8-fendvit"
        # web Zabbixu je jen na tomhle pocitaci: http://127.0.0.1:8080/
        debian.vm.network "forwarded_port", guest: 80, host: 8080, host_ip: "127.0.0.1"
        debian.vm.network "forwarded_port", guest: 22, host: 2206, host_ip: "127.0.0.1", id: "ssh"
    end

    # export hosta sposdk.cz nahraju do VM, nepotrebuju sdilenou slozku /vagrant
    config.vm.provision "file", source: "Zabbix/export/sposdk.cz_hosts.yaml", destination: "/tmp/sposdk.cz_hosts.yaml"

    # 1) MariaDB + Zabbix server, web a agent 2
    config.vm.provision "shell", path: "scripts/install-zabbix-server.sh"

    # 2) hosti v Zabbixu pres API (mistni Debian a sposdk.cz)
    config.vm.provision "shell", path: "scripts/configure-zabbix-hosts.sh"
end
