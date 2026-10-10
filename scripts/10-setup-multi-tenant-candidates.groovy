import jenkins.model.*
import hudson.security.*
import com.michelin.cio.hudson.plugins.rolestrategy.RoleBasedAuthorizationStrategy
import com.michelin.cio.hudson.plugins.rolestrategy.Role
import com.michelin.cio.hudson.plugins.rolestrategy.PermissionEntry
import com.synopsys.arc.jenkins.plugins.rolestrategy.RoleType
import com.cloudbees.hudson.plugins.folder.*
import hudson.model.Hudson
import hudson.model.Computer
import hudson.model.Item
import hudson.model.Run
import hudson.model.View
import com.cloudbees.plugins.credentials.CredentialsProvider
import java.lang.reflect.Field

def instance = Jenkins.getInstance()

println("=== CONFIGURING JENKINS MULTI-TENANCY ===")

// Clear dangerous permissions filter so custom roles can assign Plugin / UpdateCenter / SystemRead
try {
    Class phClass = Jenkins.get().pluginManager.uberClassLoader.loadClass("com.michelin.cio.hudson.plugins.rolestrategy.PermissionHelper")
    Field fDang = phClass.getDeclaredField("DANGEROUS_PERMISSIONS")
    fDang.setAccessible(true)
    Set dangSet = (Set) fDang.get(null)
    dangSet.clear()

    Field fShow = phClass.getDeclaredField("SHOW_DANGEROUS")
    fShow.setAccessible(true)
    fShow.set(null, true)
    println("Successfully cleared DANGEROUS_PERMISSIONS and enabled SHOW_DANGEROUS!")
} catch (Throwable t) {
    println("Could not modify PermissionHelper: " + t)
}

// 1. Security Realm
def hudsonRealm = new HudsonPrivateSecurityRealm(false, false, null)
instance.setSecurityRealm(hudsonRealm)

// Admin user
def adminUser = hudsonRealm.getUser("admin")
if (adminUser == null || hudsonRealm.allUsers.find { it.id == "admin" } == null) {
    hudsonRealm.createAccount("admin", "admin")
    println("Created admin account")
} else {
    adminUser.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword("admin"))
}

// Candidate users efiadmin1 .. efiadmin20
(1..20).each { i ->
    def uname = "efiadmin" + i
    def pword = "efiadmin" + i
    def user = hudsonRealm.getUser(uname)
    if (user == null || hudsonRealm.allUsers.find { it.id == uname } == null) {
        hudsonRealm.createAccount(uname, pword)
        println("Created candidate: " + uname)
    } else {
        user.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword(pword))
    }
}

// Permission helper
def getPerm = { id ->
    def perm = Permission.fromId(id)
    if (perm == null) {
        println("WARNING: Permission not found for ID: " + id)
    }
    return perm
}

// 2. Global Roles
RoleBasedAuthorizationStrategy rba = new RoleBasedAuthorizationStrategy()

Set<Permission> adminPerms = new HashSet<>()
adminPerms.add(Permission.FULL_CONTROL)
Role adminRole = new Role("admin", adminPerms)
rba.addRole(RoleType.Global, adminRole)
rba.assignRole(RoleType.Global, adminRole, PermissionEntry.user("admin"))

Set<Permission> candidateGlobalPerms = new HashSet<>()
[
    "hudson.model.Hudson.Read",
    "hudson.model.Hudson.Manage",
    "hudson.model.Hudson.SystemRead",
    "hudson.model.Hudson.UploadPlugins",
    "hudson.model.Hudson.ConfigureUpdateCenter",
    "hudson.model.Computer.Create",
    "hudson.model.Computer.Configure",
    "hudson.model.Computer.Connect",
    "hudson.model.Computer.Delete",
    "hudson.model.Computer.Disconnect",
    "hudson.model.Computer.ExtendedRead",
    "hudson.model.Computer.Provision",
    "hudson.model.Computer.Build",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Create",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Delete",
    "com.cloudbees.plugins.credentials.CredentialsProvider.ManageDomains",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Update",
    "com.cloudbees.plugins.credentials.CredentialsProvider.UseItem",
    "com.cloudbees.plugins.credentials.CredentialsProvider.UseOwn",
    "com.cloudbees.plugins.credentials.CredentialsProvider.View",
    "hudson.model.View.Create",
    "hudson.model.View.Configure",
    "hudson.model.View.Delete",
    "hudson.model.View.Read"
].each { id ->
    def p = getPerm(id)
    if (p != null) candidateGlobalPerms.add(p)
}

Role candidateGlobalRole = new Role("candidate-global", candidateGlobalPerms)
rba.addRole(RoleType.Global, candidateGlobalRole)

(1..20).each { i ->
    def uname = "efiadmin" + i
    rba.assignRole(RoleType.Global, candidateGlobalRole, PermissionEntry.user(uname))
}

// 3. Item Roles per candidate
Set<Permission> itemPerms = new HashSet<>()
[
    "hudson.model.Item.Build",
    "hudson.model.Item.Cancel",
    "hudson.model.Item.Configure",
    "hudson.model.Item.Create",
    "hudson.model.Item.Delete",
    "hudson.model.Item.Discover",
    "hudson.model.Item.ExtendedRead",
    "hudson.model.Item.Move",
    "hudson.model.Item.Read",
    "hudson.model.Item.WipeOut",
    "hudson.model.Item.Workspace",
    "hudson.model.Run.Artifacts",
    "hudson.model.Run.Delete",
    "hudson.model.Run.Replay",
    "hudson.model.Run.Update",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Create",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Delete",
    "com.cloudbees.plugins.credentials.CredentialsProvider.ManageDomains",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Update",
    "com.cloudbees.plugins.credentials.CredentialsProvider.UseItem",
    "com.cloudbees.plugins.credentials.CredentialsProvider.UseOwn",
    "com.cloudbees.plugins.credentials.CredentialsProvider.View"
].each { id ->
    def p = getPerm(id)
    if (p != null) itemPerms.add(p)
}

(1..20).each { i ->
    def uname = "efiadmin" + i
    def roleName = "role-" + uname
    def pattern = "^" + uname + "(\$|[/-].*)"
    Role candidateItemRole = new Role(roleName, pattern, itemPerms)
    rba.addRole(RoleType.Project, candidateItemRole)
    rba.assignRole(RoleType.Project, candidateItemRole, PermissionEntry.user(uname))
}

instance.setAuthorizationStrategy(rba)

// 4. Create top level folders efiadmin1 .. efiadmin20
(1..20).each { i ->
    def folderName = "efiadmin" + i
    if (instance.getItem(folderName) == null) {
        instance.createProject(Folder.class, folderName)
        println("Created folder: " + folderName)
    }
}

instance.save()

// 5. Check links for efiadmin1
def user1 = hudson.model.User.get("efiadmin1")
def auth1 = user1.impersonate2()
def cgRole = rba.getRoleMap(RoleType.Global).getRole("candidate-global")
println("=== DEBUG CANDIDATE GLOBAL ROLE PERMS ===")
println("cgRole perms: " + cgRole.permissions.collect { it.id })
println("auth1 SIDs: " + auth1.getName() + " authorities: " + auth1.getAuthorities())

println("=== FINAL MANAGEMENT LINKS CHECK FOR EFIADMIN1 ===")
Jenkins.get().getManagementLinks().each { link ->
    def perm = link.getRequiredPermission()
    def allowed = perm == null ? true : rba.getRootACL().hasPermission2(auth1, perm)
    println("Link " + link.getUrlName() + " (" + link.getDisplayName() + ") -> reqPerm: " + perm + ". ALLOWED = " + allowed)
}

println("=== JENKINS MULTI-TENANCY CONFIGURATION COMPLETE ===")
