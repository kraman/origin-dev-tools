#
# Global definitions
#

OPTIONS = {
  "fedora" => {
    "amis"            => {"us-east-1" =>"ami-6145cc08"},
    "devenv_name"     => "oso-fedora",
    "ignore_packages" => [
      'openshift-origin-util-scl', 
      'rubygem-openshift-origin-auth-kerberos', 
      'openshift-origin-cartridge-jbossews-1.0', 
      'openshift-origin-cartridge-jbossews-2.0',
      'openshift-origin-cartridge-postgresql-8.4',
      "openshift-origin-cartridge-ruby-1.8",
      "openshift-origin-cartridge-ruby-1.9-scl",
      'openshift-origin-cartridge-jbossas-7',
      'openshift-origin-cartridge-switchyard-0.6',
      'openshift-origin-cartridge-perl-5.10',
      'openshift-origin-cartridge-php-5.3',
      'openshift-origin-cartridge-python-2.6',
      'openshift-origin-cartridge-phpmyadmin-3.4',
      'openshift-origin-cartridge-jbosseap-6.0', 
      'openshift-origin-cartridge-jbossas-7',
      "openshift-origin-cartridge-switchyard-0.6"
    ],
    "cucumber_options"        => '--strict -f progress -f junit --out /tmp/rhc/cucumber_results -t ~@rhel-only',
    "broker_cucumber_options" => '--strict -f html --out /tmp/rhc/broker_cucumber.html -f progress  -t ~@rhel-only',
  },
  "rhel"   => {
    "amis"            => {"us-east-1" =>"ami-cc5af9a5"},
    "devenv_name"     => "oso-rhel",
    "ignore_packages" => [
      'rubygem-openshift-origin-auth-kerberos', 
      'openshift-origin-cartridge-jbossews-1.0', 
      'openshift-origin-cartridge-jbossews-2.0',
      'openshift-origin-cartridge-jbosseap-6.0', 
      'openshift-origin-cartridge-jbossas-7',
      "openshift-origin-cartridge-switchyard-0.6",
      "openshift-origin-cartridge-ruby-1.9",
      'openshift-origin-cartridge-perl-5.16',
      'openshift-origin-cartridge-php-5.4',
      'openshift-origin-cartridge-phpmyadmin-3.5',
      'openshift-origin-cartridge-postgresql-9.1',
    ],
    "cucumber_options"        => '--strict -f progress -f junit --out /tmp/rhc/cucumber_results -t ~@fedora-only',
    "broker_cucumber_options" => '--strict -f html --out /tmp/rhc/broker_cucumber.html -f progress  -t ~@fedora-only',    
  },
}

TYPE = "m1.large"
ZONE = 'us-east-1d'
VERIFIER_REGEXS = {}
TERMINATE_REGEX = /terminate/
VERIFIED_TAG = "qe-ready"

# Specify the source location of the SSH key
# This will be used if the key is not found at the location specified by "RSA"
KEY_PAIR = "libra"
RSA = File.expand_path("~/.ssh/devenv.pem")
RSA_SOURCE = ""

SAUCE_USER = ""
SAUCE_SECRET = ""
SAUCE_OS = ""
SAUCE_BROWSER = ""
SAUCE_BROWSER_VERSION = ""
CAN_SSH_TIMEOUT=90
SLEEP_AFTER_LAUNCH=60

SIBLING_REPOS = {
  'origin-server' => ['../origin-server'],
  'rhc' => ['../rhc'],
  'origin-dev-tools' => ['../origin-dev-tools'],
  'origin-community-cartridges' => ['../origin-community-cartridges'],                  
  'puppet-openshift_origin' => ['../puppet-openshift_origin'],
}
OPENSHIFT_ARCHIVE_DIR_MAP = {'rhc' => 'rhc/'}
SIBLING_REPOS_GIT_URL = {
  'origin-server' => 'https://github.com/openshift/origin-server.git',
  'rhc' => 'https://github.com/openshift/rhc.git',
  'origin-dev-tools' => 'https://github.com/openshift/origin-dev-tools.git',
  'origin-community-cartridges' => 'https://github.com/openshift/origin-community-cartridges.git',
  'puppet-openshift_origin' => 'https://github.com/openshift/puppet-openshift_origin.git'
}

DEV_TOOLS_REPO = 'origin-dev-tools'
DEV_TOOLS_EXT_REPO = DEV_TOOLS_REPO
ADDTL_SIBLING_REPOS = SIBLING_REPOS_GIT_URL.keys - [DEV_TOOLS_REPO]
ACCEPT_DEVENV_SCRIPT = 'true'
$amz_options = {:key_name => KEY_PAIR, :instance_type => TYPE}
