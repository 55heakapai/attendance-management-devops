#!/bin/bash
# ============================================================
#  AWS INFRASTRUCTURE SETUP SCRIPT
#  Attendance Management System — Complete Setup
#  Run once before any Jenkins pipelines execute
# ============================================================

set -euo pipefail

# ── CONFIGURATION — Edit these ────────────────────────────────
AWS_REGION="ap-south-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO_NAME="attendance-system"
KEY_PAIR_NAME="attendance-key"
VPC_CIDR="10.0.0.0/16"
SUBNET_A_CIDR="10.0.1.0/24"
SUBNET_B_CIDR="10.0.2.0/24"
AMI_ID="ami-0f5ee92e2d63afc18"   # Amazon Linux 2023 ap-south-1

echo "=============================================="
echo " Attendance System AWS Setup"
echo " Account : $AWS_ACCOUNT_ID"
echo " Region  : $AWS_REGION"
echo "=============================================="

# ══════════════════════════════════════════════════════════════
#  PART 1: ECR REPOSITORY
# ══════════════════════════════════════════════════════════════
echo ""
echo "─── 1. Creating ECR Repository ─────────────────────────"

aws ecr create-repository \
    --repository-name $ECR_REPO_NAME \
    --region $AWS_REGION \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE \
    --query 'repository.repositoryUri' \
    --output text 2>/dev/null || echo "ECR repo already exists"

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
echo "✅ ECR URI: $ECR_URI"

# Enable lifecycle policy (keep last 10 images)
aws ecr put-lifecycle-policy \
    --repository-name $ECR_REPO_NAME \
    --region $AWS_REGION \
    --lifecycle-policy-text '{
        "rules": [{
            "rulePriority": 1,
            "description": "Keep last 10 images",
            "selection": {
                "tagStatus": "any",
                "countType": "imageCountMoreThan",
                "countNumber": 10
            },
            "action": {"type": "expire"}
        }]
    }' 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
#  PART 2: VPC + NETWORKING
# ══════════════════════════════════════════════════════════════
echo ""
echo "─── 2. Setting up VPC & Networking ─────────────────────"

VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --region $AWS_REGION \
    --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 create-tags --resources $VPC_ID \
    --tags Key=Name,Value=attendance-vpc Key=Project,Value=attendance
echo "✅ VPC: $VPC_ID"

# Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
    --region $AWS_REGION \
    --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
echo "✅ IGW: $IGW_ID"

# Subnets in two AZs (for ALB)
SUBNET_A_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $SUBNET_A_CIDR \
    --availability-zone ${AWS_REGION}a \
    --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_A_ID --map-public-ip-on-launch
aws ec2 create-tags --resources $SUBNET_A_ID \
    --tags Key=Name,Value=attendance-subnet-a

SUBNET_B_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $SUBNET_B_CIDR \
    --availability-zone ${AWS_REGION}b \
    --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_B_ID --map-public-ip-on-launch
aws ec2 create-tags --resources $SUBNET_B_ID \
    --tags Key=Name,Value=attendance-subnet-b
echo "✅ Subnets: $SUBNET_A_ID, $SUBNET_B_ID"

# Route Table
RTB_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RTB_ID \
    --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $SUBNET_A_ID
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $SUBNET_B_ID
echo "✅ Route Table configured"

# ══════════════════════════════════════════════════════════════
#  PART 3: SECURITY GROUPS
# ══════════════════════════════════════════════════════════════
echo ""
echo "─── 3. Creating Security Groups ────────────────────────"

# ALB Security Group (public HTTP)
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name attendance-alb-sg \
    --description "ALB security group for Attendance app" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID \
    --protocol tcp --port 443 --cidr 0.0.0.0/0
echo "✅ ALB SG: $ALB_SG_ID"

# EC2 Security Group (only from ALB + SSH)
EC2_SG_ID=$(aws ec2 create-security-group \
    --group-name attendance-ec2-sg \
    --description "EC2 security group for Attendance app" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG_ID \
    --protocol tcp --port 8080 --source-group $ALB_SG_ID
aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG_ID \
    --protocol tcp --port 22 --cidr 0.0.0.0/0   # restrict to your IP in prod
echo "✅ EC2 SG: $EC2_SG_ID"

# ══════════════════════════════════════════════════════════════
#  PART 4: EC2 KEY PAIR
# ══════════════════════════════════════════════════════════════
echo ""
echo "─── 4. Creating EC2 Key Pair ───────────────────────────"

aws ec2 create-key-pair \
    --key-name $KEY_PAIR_NAME \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/${KEY_PAIR_NAME}.pem 2>/dev/null || echo "Key pair already exists"
chmod 400 ~/.ssh/${KEY_PAIR_NAME}.pem 2>/dev/null || true
echo "✅ Key: ~/.ssh/${KEY_PAIR_NAME}.pem"

# ══════════════════════════════════════════════════════════════
#  PART 5: IAM ROLE FOR EC2 (ECR Pull)
# ══════════════════════════════════════════════════════════════
echo ""
echo "─── 5. Creating IAM Role for EC2 ───────────────────────"

aws iam create-role \
    --role-name AttendanceEC2Role \
    --assume-role-policy-document '{
        "Version":"2012-10-17",
        "Statement":[{
            "Effect":"Allow",
            "Principal":{"Service":"ec2.amazonaws.com"},
            "Action":"sts:AssumeRole"
        }]
    }' 2>/dev/null || echo "IAM role already exists"

aws iam attach-role-policy \
    --role-name AttendanceEC2Role \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
    2>/dev/null || true
aws iam attach-role-policy \
    --role-name AttendanceEC2Role \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
    2>/dev/null || true

INSTANCE_PROFILE=$(aws iam create-instance-profile \
    --instance-profile-name AttendanceEC2Profile \
    --query 'InstanceProfile.InstanceProfileName' \
    --output text 2>/dev/null || echo "AttendanceEC2Profile")
aws iam add-role-to-instance-profile \
    --instance-profile-name AttendanceEC2Profile \
    --role-name AttendanceEC2Role 2>/dev/null || true
echo "✅ IAM Role + Instance Profile ready"
sleep 10  # Let IAM propagate

# ══════════════════════════════════════════════════════════════
#  PART 6: EC2 INSTANCES (2 for HA)
# ══════════════════════════════════════════════════════════════
echo ""
echo "─── 6. Launching EC2 Instances ─────────────────────────"

USER_DATA=$(cat << 'USERDATA'
#!/bin/bash
yum update -y
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user
# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
USERDATA
)

EC2_1_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t3.small \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $EC2_SG_ID \
    --subnet-id $SUBNET_A_ID \
    --iam-instance-profile Name=AttendanceEC2Profile \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=attendance-server-1},{Key=Project,Value=attendance}]" \
    --query 'Instances[0].InstanceId' --output text)
echo "✅ EC2 Instance 1: $EC2_1_ID"

EC2_2_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t3.small \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $EC2_SG_ID \
    --subnet-id $SUBNET_B_ID \
    --iam-instance-profile Name=AttendanceEC2Profile \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=attendance-server-2},{Key=Project,Value=attendance}]" \
    --query 'Instances[0].InstanceId' --output text)
echo "✅ EC2 Instance 2: $EC2_2_ID"

echo "⏳ Waiting for instances to be running..."
aws ec2 wait instance-running --instance-ids $EC2_1_ID $EC2_2_ID
echo "✅ Both instances are running"

EC2_1_IP=$(aws ec2 describe-instances \
    --instance-ids $EC2_1_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
EC2_2_IP=$(aws ec2 describe-instances \
    --instance-ids $EC2_2_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "✅ IPs: $EC2_1_IP, $EC2_2_IP"

# ══════════════════════════════════════════════════════════════
#  PART 7: APPLICATION LOAD BALANCER (PHASE 3 BONUS)
# ══════════════════════════════════════════════════════════════
echo ""
echo "─── 7. Creating Application Load Balancer ───────────────"

# Target Group
TG_ARN=$(aws elbv2 create-target-group \
    --name attendance-tg \
    --protocol HTTP \
    --port 8080 \
    --vpc-id $VPC_ID \
    --target-type instance \
    --health-check-path /attendance/status \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 10 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "✅ Target Group: $TG_ARN"

# Register both EC2 instances
aws elbv2 register-targets \
    --target-group-arn $TG_ARN \
    --targets Id=$EC2_1_ID,Port=8080 Id=$EC2_2_ID,Port=8080
echo "✅ Both instances registered in Target Group"

# ALB
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name attendance-alb \
    --subnets $SUBNET_A_ID $SUBNET_B_ID \
    --security-groups $ALB_SG_ID \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --tags Key=Project,Value=attendance \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
echo "✅ ALB: $ALB_ARN"

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].DNSName' --output text)
echo "✅ ALB DNS: $ALB_DNS"

# Listener: HTTP → Target Group
aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN
echo "✅ Listener created"

# ══════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════
echo ""
echo "=============================================="
echo " ✅ ALL RESOURCES CREATED"
echo "=============================================="
echo " ECR URI       : $ECR_URI"
echo " VPC           : $VPC_ID"
echo " EC2 Instance1 : $EC2_1_ID  ($EC2_1_IP)"
echo " EC2 Instance2 : $EC2_2_ID  ($EC2_2_IP)"
echo " Target Group  : $TG_ARN"
echo " ALB DNS       : http://$ALB_DNS"
echo ""
echo " Test endpoints:"
echo "   GET  http://$ALB_DNS/attendance/status"
echo "   POST http://$ALB_DNS/attendance/checkin"
echo ""
echo " Jenkins Credentials to configure:"
echo "   aws-account-id       → $AWS_ACCOUNT_ID"
echo "   ec2-prod-hosts       → $EC2_1_IP,$EC2_2_IP"
echo "   ec2-staging-hosts    → $EC2_1_IP"
echo "=============================================="

# Save to file for reference
cat > ~/attendance-infra.env << EOF
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
ECR_URI=$ECR_URI
VPC_ID=$VPC_ID
SUBNET_A_ID=$SUBNET_A_ID
SUBNET_B_ID=$SUBNET_B_ID
EC2_1_ID=$EC2_1_ID
EC2_1_IP=$EC2_1_IP
EC2_2_ID=$EC2_2_ID
EC2_2_IP=$EC2_2_IP
TG_ARN=$TG_ARN
ALB_ARN=$ALB_ARN
ALB_DNS=$ALB_DNS
KEY_NAME=$KEY_PAIR_NAME
EOF
echo "📄 Saved to ~/attendance-infra.env"
