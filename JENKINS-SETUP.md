# Jenkins Setup Guide — Attendance Management System

## 1. Jenkins Installation (Ubuntu EC2 or local)

```bash
# Java 17
sudo apt update && sudo apt install -y openjdk-17-jdk

# Jenkins LTS
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update && sudo apt install -y jenkins
sudo systemctl enable --now jenkins

# Docker (for building images)
sudo apt install -y docker.io
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Get initial admin password
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Access Jenkins: http://YOUR_JENKINS_IP:8080

---

## 2. Required Jenkins Plugins

Install via Manage Jenkins → Plugins → Available:
- **Git** (already installed)
- **GitHub Integration** (webhook trigger)
- **Pipeline**
- **Amazon ECR**
- **CloudBees AWS Credentials**
- **SSH Agent**
- **Email Extension (Email-ext)**
- **JUnit**
- **Workspace Cleanup**

---

## 3. Jenkins Credentials (Manage Jenkins → Credentials)

| ID                   | Type                          | Value                                    |
|----------------------|-------------------------------|------------------------------------------|
| `aws-credentials`    | AWS Credentials               | Your IAM Access Key + Secret Key         |
| `aws-account-id`     | Secret Text                   | Your 12-digit AWS Account ID             |
| `ec2-ssh-key`        | SSH Username with Private Key | ec2-user + contents of .pem file         |
| `ec2-prod-hosts`     | Secret Text                   | `1.2.3.4,5.6.7.8` (both EC2 public IPs) |
| `ec2-staging-hosts`  | Secret Text                   | `1.2.3.4` (first EC2 only)               |

---

## 4. Configure Email Notifications

Manage Jenkins → Configure System → Email Notification / Extended E-mail:

```
SMTP Server   : smtp.gmail.com
SMTP Port     : 465
Use SSL       : ✅
Credentials   : Gmail App Password (not your account password)
From          : your-email@gmail.com
```

For Gmail App Password:
1. Google Account → Security → 2-Step Verification → App passwords
2. Create "Jenkins" app password → copy 16-char code
3. Add as Jenkins credential (Secret Text), reference in SMTP config

---

## 5. Create CI Pipeline Job

1. New Item → **attendance-ci** → Pipeline
2. Check ✅ **GitHub project** → URL: `https://github.com/YOUR/repo`
3. Build Triggers → ✅ **GitHub hook trigger for GITScm polling**
4. Pipeline → Definition: **Pipeline script from SCM**
   - SCM: Git
   - Repository URL: `https://github.com/YOUR/repo.git`
   - Credentials: add GitHub token
   - Branch: `*/main`
   - Script Path: `Jenkinsfile.ci`
5. Save

---

## 6. Create CD Pipeline Job

1. New Item → **attendance-cd** → Pipeline
2. Check ✅ **This project is parameterized** (auto-detected from Jenkinsfile)
3. Pipeline → Script Path: `Jenkinsfile.cd`
4. Save

---

## 7. GitHub Webhook Setup

In your GitHub repository:
1. Settings → Webhooks → Add webhook
2. **Payload URL**: `http://YOUR_JENKINS_IP:8080/github-webhook/`
3. **Content type**: `application/json`
4. **Which events**: Just the push event
5. ✅ Active → Add webhook

Verify: Push to main → Jenkins CI job auto-triggers within seconds.

---

## 8. Test Everything

```bash
# Test CI trigger
git add .
git commit -m "test: trigger CI pipeline"
git push origin main
# → Jenkins CI job starts automatically

# Test endpoints after deploy
ALB_DNS="your-alb-dns.ap-south-1.elb.amazonaws.com"

curl http://$ALB_DNS/attendance/status

curl -X POST http://$ALB_DNS/attendance/checkin \
  -H "Content-Type: application/json" \
  -d '{"userId":"u001","userName":"Hea","location":"IIT Bombay Lab 3"}'
```

---

## 9. Pipeline Flow Diagram

```
GitHub Push
    │
    ▼
Jenkins CI (Jenkinsfile.ci)
    │
    ├─ Checkout
    ├─ mvn test
    ├─ mvn package
    ├─ docker build -t <ECR>:<BUILD_NUM>
    ├─ aws ecr get-login-password | docker login
    ├─ docker push
    └─ Email notification (success/fail)
             │
             ▼ (manual trigger)
Jenkins CD (Jenkinsfile.cd)
    │
    ├─ Parameters: ENVIRONMENT, BUILD_NUMBER_TO_DEPLOY
    ├─ Verify image in ECR
    ├─ SSH → EC2 #1: docker pull + docker run
    ├─ SSH → EC2 #2: docker pull + docker run (Production only)
    ├─ Health check /attendance/status
    └─ Email notification
             │
             ▼
    ALB routes traffic across both EC2s
    http://<ALB-DNS>/attendance/status
    http://<ALB-DNS>/attendance/checkin
```
