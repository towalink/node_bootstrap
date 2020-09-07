# Towalink Node Bootstrap

Bootstraps a Towalink Node.

---

## Installation

The bootstrap script can be run on Alpine Linux, Debian Linux, or Raspbian. Other platforms are not officially supported yet.

To quickly and conveniently install a Towalink Node run the following command as user with root privileges:
```shell
bash <(wget -qO- https://install.towalink.net/node/) 
```
The script will install required software packages and the script itself, make sure the script runs again at boot time, and attempts to connect to a Towalink Controller.
After a Node is prepared like this, a node attach can be done on the Towalink Controller.

Advanced installation options:
```shell
bash <(wget -qO- https://install.towalink.net/node/) -v
bash <(wget -qO- https://install.towalink.net/node/) -c <hostname of controller>
bash <(wget -qO- https://install.towalink.net/node/) -v -c <hostname or IP of controller>
```

Please read the documentation (link below) for further information.

---

## Documentation

The documentation of the Towalink project can be found at https://towalink.readthedocs.io

---

## License

[![License](http://img.shields.io/:license-gpl3-blue.svg?style=flat-square)](http://opensource.org/licenses/gpl-license.php)

- **[GPL3 license](http://opensource.org/licenses/gpl-license.php)**
- Copyright 2020 © <a href="https://www.towalink.net" target="_blank">Towalink</a>.
