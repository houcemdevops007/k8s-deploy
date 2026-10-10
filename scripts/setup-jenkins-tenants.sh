#!/usr/bin/env bash
# Script d'installation et de configuration Multi-Tenant Jenkins pour 20 candidats (efiadmin1 -> efiadmin20)
# VM Jenkins IP: 172.16.3.14

JENKINS_HOST="172.16.3.14"

echo "=== Configuration Multi-Tenant Jenkins sur ${JENKINS_HOST} ==="

ssh -o BatchMode=yes efi@${JENKINS_HOST} 'sudo python3 -c "
script = \"\"\"import jenkins.model.*
import hudson.security.*
import com.michelin.cio.hudson.plugins.rolestrategy.*
import com.synopsys.arc.jenkins.plugins.rolestrategy.*
import com.cloudbees.hudson.plugins.folder.*
import hudson.model.Hudson

def instance = Jenkins.getInstance()

println(\\\"=== CONFIGURING JENKINS MULTI-TENANCY ===\\\")

// 1. Security Realm (Local Jenkins DB)
def hudsonRealm = new HudsonPrivateSecurityRealm(false, false, null)
instance.setSecurityRealm(hudsonRealm)

// Admin account
def adminUser = hudsonRealm.getUser(\\\"admin\\\")
if (adminUser == null || hudsonRealm.allUsers.find { it.id == \\\"admin\\\" } == null) {
    hudsonRealm.createAccount(\\\"admin\\\", \\\"admin\\\")
} else {
    adminUser.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword(\\\"admin\\\"))
}

// Candidates efiadmin1 .. efiadmin20
(1..20).each { i ->
    def uname = \\\"efiadmin\${i}\\\"
    def pword = \\\"efiadmin\${i}\\\"
    def user = hudsonRealm.getUser(uname)
    if (user == null || hudsonRealm.allUsers.find { it.id == uname } == null) {
        hudsonRealm.createAccount(uname, pword)
    } else {
        user.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword(pword))
    }
}

// Permission lookup helper
def getPerm = { id ->
    return Permission.fromId(id)
}

// 2. Authorization Strategy
RoleBasedAuthorizationStrategy rba = new RoleBasedAuthorizationStrategy()
RoleMap globalMap = rba.getRoleMap(RoleType.Global)
RoleMap projectMap = rba.getRoleMap(RoleType.Project)

// Admin Global Role
Set<Permission> adminPerms = new HashSet<>()
adminPerms.add(getPerm(\\\"hudson.model.Hudson.Administer\\\"))
Role adminRole = new Role(\\\"admin\\\", adminPerms)
globalMap.addRole(adminRole)
globalMap.assignRole(adminRole, \\\"admin\\\")

// Candidates Global Role
Set<Permission> candidateGlobalPerms = new HashSet<>()
[
    \\\"hudson.model.Hudson.Read\\\",
    \\\"hudson.model.Hudson.Manage\\\",
    \\\"hudson.model.Hudson.UploadPlugins\\\",
    \\\"hudson.model.Hudson.ConfigureUpdateCenter\\\",
    \\\"hudson.model.Computer.Create\\\",
    \\\"hudson.model.Computer.Configure\\\",
    \\\"hudson.model.Computer.Connect\\\",
    \\\"hudson.model.Computer.Delete\\\",
    \\\"hudson.model.Computer.Disconnect\\\",
    \\\"hudson.model.Computer.ExtendedRead\\\",
    \\\"hudson.model.Computer.Provision\\\",
    \\\"hudson.model.Computer.Build\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.Create\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.Delete\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.ManageDomains\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.Update\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.UseItem\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.UseOwn\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.View\\\",
    \\\"hudson.model.View.Create\\\",
    \\\"hudson.model.View.Configure\\\",
    \\\"hudson.model.View.Delete\\\",
    \\\"hudson.model.View.Read\\\"
].each { id ->
    def p = getPerm(id)
    if (p != null) candidateGlobalPerms.add(p)
}

Role candidateGlobalRole = new Role(\\\"candidate-global\\\", candidateGlobalPerms)
globalMap.addRole(candidateGlobalRole)

(1..20).each { i ->
    globalMap.assignRole(candidateGlobalRole, \\\"efiadmin\${i}\\\")
}

// 3. Item Roles per Candidate (Strict boundaries)
Set<Permission> itemPerms = new HashSet<>()
[
    \\\"hudson.model.Item.Build\\\",
    \\\"hudson.model.Item.Cancel\\\",
    \\\"hudson.model.Item.Configure\\\",
    \\\"hudson.model.Item.Create\\\",
    \\\"hudson.model.Item.Delete\\\",
    \\\"hudson.model.Item.Discover\\\",
    \\\"hudson.model.Item.ExtendedRead\\\",
    \\\"hudson.model.Item.Move\\\",
    \\\"hudson.model.Item.Read\\\",
    \\\"hudson.model.Item.WipeOut\\\",
    \\\"hudson.model.Item.Workspace\\\",
    \\\"hudson.model.Run.Artifacts\\\",
    \\\"hudson.model.Run.Delete\\\",
    \\\"hudson.model.Run.Replay\\\",
    \\\"hudson.model.Run.Update\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.Create\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.Delete\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.ManageDomains\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.Update\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.UseItem\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.UseOwn\\\",
    \\\"com.cloudbees.plugins.credentials.CredentialsProvider.View\\\"
].each { id ->
    def p = getPerm(id)
    if (p != null) itemPerms.add(p)
}

(1..20).each { i ->
    def uname = \\\"efiadmin\${i}\\\"
    def roleName = \\\"role-\${uname}\\\"
    def pattern = \\\"^\${uname}(\\\$|[/-].*)\\\"
    Role candidateItemRole = new Role(roleName, pattern, itemPerms)
    projectMap.addRole(candidateItemRole)
    projectMap.assignRole(candidateItemRole, uname)
}

instance.setAuthorizationStrategy(rba)

// 4. Create top-level folders efiadmin1 .. efiadmin20
(1..20).each { i ->
    def folderName = \\\"efiadmin\${i}\\\"
    if (instance.getItem(folderName) == null) {
        instance.createProject(Folder.class, folderName)
        println(\\\"Created folder: \${folderName}\\\")
    }
}

instance.save()
println(\\\"=== JENKINS MULTI-TENANCY CONFIGURATION COMPLETE ===\\\")
\"\"\"
with open(\"/var/lib/jenkins/init.groovy.d/10-setup-multi-tenant-candidates.groovy\", \"w\") as f:
    f.write(script)
" && sudo chown -R jenkins:jenkins /var/lib/jenkins/init.groovy.d && sudo systemctl reset-failed jenkins && sudo systemctl restart jenkins'
