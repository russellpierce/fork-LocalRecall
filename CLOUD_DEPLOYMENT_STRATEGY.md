# Cloud Deployment Strategy for LocalRecall

## Executive Summary

After analyzing the existing AWS deployment proposal and the application architecture, I propose a **hybrid approach** that addresses the application's unique requirements while providing flexibility for different deployment scenarios.

## Application Architecture Analysis

### Current Design
LocalRecall is a stateful, long-running web service with:
- **Web Server**: Echo framework (Go) handling RESTful API requests
- **Vector Database**: Chromem (local) or LocalAI stores for embeddings
- **Persistent Storage**:
  - JSON metadata files (collection state)
  - Uploaded file assets (PDFs, text, markdown)
  - Vector database files
- **Background Services**: Source manager polling external sources every minute
- **In-Memory State**: Collections map requiring initialization on startup

### Key Deployment Challenges

1. **Filesystem Dependency**: All data stored on local filesystem
2. **Long-Running Process**: Designed as persistent service, not stateless functions
3. **Background Workers**: Continuous source update polling
4. **State Synchronization**: Collections loaded at startup from disk
5. **Concurrency**: Mutex-based file locking for thread safety
6. **Cold Start**: Vector DB and collections must be loaded into memory

## Proposed Deployment Strategy

### Primary Recommendation: AWS Fargate with EFS (Low-Cost Production)

**Architecture:**
```
┌─────────────────────────────────────────────────────────┐
│                    Application Load Balancer            │
└────────────┬──────────────────────────────┬─────────────┘
             │                              │
      ┌──────▼──────┐              ┌────────▼──────┐
      │  Fargate    │              │   Fargate     │
      │   Task 1    │              │   Task 2      │
      │             │              │               │
      └──────┬──────┘              └────────┬──────┘
             │                              │
             └──────────┬───────────────────┘
                        │
                ┌───────▼──────────┐
                │   Amazon EFS     │
                │                  │
                │ /db (vector DB)  │
                │ /assets (files)  │
                └──────────────────┘
```

**Benefits:**
- ✅ **Minimal Code Changes**: Uses existing Dockerfile
- ✅ **Scale-to-Zero**: ECS Service Auto Scaling with min capacity = 0
- ✅ **Persistent Storage**: EFS for shared filesystem across tasks
- ✅ **Background Workers**: Long-running containers support continuous processes
- ✅ **Cost Effective**: Pay only for running tasks + EFS storage

**Implementation Steps:**
1. Build and push Docker image to Amazon ECR
2. Create EFS filesystem with two access points (`/db`, `/assets`)
3. Create ECS Task Definition mounting EFS volumes
4. Deploy ECS Service on Fargate with ALB
5. Configure Service Auto Scaling:
   - Min capacity: 0
   - Max capacity: 10+
   - Metric: ALBRequestCountPerTarget
   - Scale-in cooldown: 5 minutes (to handle background workers gracefully)

**Considerations:**
- **File Locking**: The application's mutex-based locking works within a single task, but EFS requires NFS file locking for multi-task deployments
- **Cold Starts**: Scaling from 0 to 1 task takes ~30-60 seconds (container startup + EFS mount + collection loading)
- **Cost**: EFS storage (~$0.30/GB/month) + Fargate compute (when running)

### Alternative: AWS Lambda with EFS (Experimental Serverless)

**When to Consider:**
- Truly sporadic usage (< 1 hour/day)
- Willing to accept cold start penalties
- Want maximum cost optimization for idle periods

**Architecture Modifications Required:**
1. **Split Application into Functions:**
   - `handleAPIRequest`: Process individual API endpoints
   - `backgroundWorker`: Separate Lambda for source updates (EventBridge schedule)

2. **Refactor Initialization:**
   - Lazy-load collections on demand
   - Cache loaded collections in Lambda execution context
   - Use Lambda reserved concurrency to control EFS connections

3. **Background Worker Solution:**
   - EventBridge rule triggers Lambda every 1 minute
   - Lambda processes all due source updates
   - Stores results in EFS

**Challenges:**
- ⚠️ **Significant Refactoring**: Application not designed for function-based execution
- ⚠️ **Cold Starts**: 2-5 seconds for EFS mount + vector DB loading
- ⚠️ **Complexity**: Split architecture harder to maintain
- ⚠️ **Concurrency Limits**: EFS has connection limits per access point

**Not Recommended** unless usage patterns are extremely sporadic (< 1 request/hour).

### Advanced Option: Serverless Containers with AWS App Runner

**Benefits:**
- Simpler than Fargate (no ECS/VPC management)
- Automatic HTTPS endpoint
- Built-in autoscaling
- Can scale to zero

**Limitations:**
- ❌ No EFS support (must use S3 or external storage)
- ❌ Requires code changes to use S3 instead of local filesystem
- ❌ Background workers need separate service

### Cloud-Native Refactor: Distributed Architecture (Future State)

For true cloud-native scalability, consider refactoring to:

```
┌─────────────────────┐
│   API Gateway       │
└──────────┬──────────┘
           │
    ┌──────▼───────┐
    │   Lambda or  │
    │   Fargate    │
    │   (Stateless)│
    └──────┬───────┘
           │
    ┌──────▼───────────────────────┐
    │   Managed Vector Database    │
    │   (AWS OpenSearch Serverless │
    │    or Pinecone/Weaviate)     │
    └──────────────────────────────┘
           │
    ┌──────▼───────┐
    │   S3 Bucket  │
    │  (File Assets)│
    └──────────────┘
```

**Changes Required:**
1. Replace Chromem with managed vector DB (OpenSearch, Pinecone, Qdrant Cloud)
2. Store files in S3 instead of local filesystem
3. Store collection metadata in DynamoDB
4. Background workers as separate Lambda functions with EventBridge
5. API becomes fully stateless

**Benefits:**
- True horizontal scalability
- No shared filesystem bottlenecks
- Better performance for vector search
- Easier multi-region deployment

**Cost:**
- Higher (managed services are expensive)
- Best for high-traffic production workloads

## Recommended Approach by Use Case

| Use Case | Recommendation | Rationale |
|----------|----------------|-----------|
| **Development/Testing** | Docker Compose (current) | No infrastructure costs |
| **Low-traffic production (<100 req/hour)** | Fargate + EFS | Best cost/complexity balance |
| **Medium-traffic (100-1000 req/hour)** | Fargate + EFS (multiple tasks) | Scale horizontally, add file locking |
| **High-traffic (>1000 req/hour)** | Cloud-native refactor | Managed services justify cost |
| **Extreme cost optimization** | Lambda + EFS | Only if usage is < 1 hour/day |

## Implementation Priorities

### Phase 1: Fargate + EFS (Immediate)
1. Create Terraform/CloudFormation templates for infrastructure
2. Add health check endpoint (`/health`)
3. Test file locking behavior with multiple EFS-mounted tasks
4. Document deployment process
5. Set up CI/CD pipeline

### Phase 2: Enhanced Monitoring (Within 1 month)
1. Add CloudWatch metrics for collection operations
2. Set up alarms for EFS connection limits
3. Monitor cold start times and adjust scaling policies
4. Track cost metrics

### Phase 3: Optimization (Future)
1. Evaluate managed vector databases for performance comparison
2. Consider read replicas for search-heavy workloads
3. Implement caching layer (ElastiCache) for frequent queries
4. Add CDN (CloudFront) for static assets

## File Locking Solution for Multi-Task EFS

The application uses Go mutexes for concurrency control, which only work within a single process. For multi-task Fargate deployments with shared EFS, implement:

```go
import "github.com/gofrs/flock"

type PersistentKB struct {
    // ... existing fields
    fileLock *flock.Flock
}

func (db *PersistentKB) Lock() {
    // Use file-based lock for EFS compatibility
    db.fileLock = flock.New(db.path + ".lock")
    db.fileLock.Lock()
}

func (db *PersistentKB) Unlock() {
    db.fileLock.Unlock()
}
```

This enables safe concurrent access across multiple Fargate tasks sharing the same EFS filesystem.

## Cost Estimation (Fargate + EFS)

**Assumptions:**
- 2 vCPU, 4 GB RAM Fargate task
- Average 4 hours/day runtime (scales to zero overnight)
- 10 GB EFS storage

**Monthly Cost:**
- Fargate compute: 120 hours × $0.04/hour = $4.80
- EFS storage: 10 GB × $0.30/GB = $3.00
- ALB: ~$16.00 (1 LCU)
- **Total: ~$24/month**

Compare to always-on EC2 t3.small: ~$15/month (no auto-scaling)

## Conclusion

**Immediate Action:** Deploy on **AWS Fargate with EFS** for production use.

This approach:
- Requires minimal code changes
- Achieves scale-to-zero cost savings
- Maintains application's current architecture
- Provides clear upgrade path to cloud-native design

The existing AWS Lambda proposal is well-researched but overcomplicates deployment for an application designed as a long-running service. Lambda should only be considered after validating extremely sporadic usage patterns.
