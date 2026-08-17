# SpareLink Architecture

## Order-to-payment sequence

```mermaid
sequenceDiagram
    participant Customer
    participant Order as Order Service
    participant Catalogue as Catalogue Service
    participant Kafka
    participant Inventory as Inventory Service
    participant Payment as Payment Service

    Customer->>Order: Create order (customer JWT)
    Order->>Catalogue: Look up requested parts and prices
    Catalogue-->>Order: Part details
    Order->>Order: Persist order and order-created outbox event
    Order->>Kafka: Publish order-created
    Kafka->>Inventory: Consume order-created
    Inventory->>Inventory: Reserve stock
    Inventory->>Kafka: Publish stock-reserved
    Kafka->>Order: Consume stock-reserved
    Order->>Order: STOCK_RESERVED → PAYMENT_PENDING
    Kafka->>Payment: Consume order-created
    Payment->>Payment: Create PENDING payment
    Customer->>Payment: Read payment (customer JWT)
    Note over Payment: Admin performs status transition
    Payment->>Kafka: Publish payment-status-changed
    Kafka->>Order: Consume payment-status-changed
    Order->>Order: PAID or PAYMENT_FAILED
    Kafka->>Inventory: Consume payment-status-changed
    Note over Inventory: Release reservation when payment fails
```

## Database ownership

Every service owns its database. The shared PostgreSQL container in local Docker Compose is an infrastructure convenience, not a shared data model.

```mermaid
erDiagram
    ORDERS ||--o{ ORDER_ITEMS : contains
    ORDERS ||--o{ OUTBOX_EVENTS : records
    ORDERS {
        uuid id PK
        uuid customer_id
        string status
        decimal total_amount
        bigint version
    }
    ORDER_ITEMS {
        uuid id PK
        uuid order_id FK
        uuid part_id
        int quantity
        decimal unit_price
    }
    OUTBOX_EVENTS {
        uuid id PK
        uuid aggregate_id
        string topic
        boolean published
        int attempt_count
    }
```

```mermaid
erDiagram
    STOCK_LEVELS ||--o{ RESERVATIONS : supports
    STOCK_LEVELS {
        bigint id PK
        string part_id UK
        int available_quantity
        int reserved_quantity
        bigint version
    }
    RESERVATIONS {
        bigint id PK
        string order_id
        string part_id
        int quantity
        string status
    }
```

```mermaid
erDiagram
    PAYMENTS ||--o{ PAYMENT_OUTBOX_EVENTS : records
    PAYMENTS {
        uuid id PK
        uuid order_id UK
        uuid customer_id
        decimal amount
        string status
    }
    PAYMENT_OUTBOX_EVENTS {
        uuid id PK
        uuid aggregate_id
        string topic
        boolean published
        datetime created_at
    }
```

```mermaid
erDiagram
    BRANDS ||--o{ PARTS : owns
    CATEGORIES ||--o{ PARTS : classifies
    CATEGORIES ||--o{ CATEGORIES : parents
    PARTS ||--o{ PART_IMAGES : has
    PARTS ||--o{ VEHICLE_FITMENTS : fits
    BRANDS {
        uuid id PK
        string name
    }
    CATEGORIES {
        uuid id PK
        string name
        uuid parent_id
    }
    PARTS {
        uuid id PK
        string sku UK
        string name
        bigint amount
        string currency
        string status
        bigint version
    }
```

## Testing strategy

| Layer | Purpose | Technology |
| --- | --- | --- |
| Domain and service tests | Business rules, idempotency, and valid state transitions | JUnit 5, Mockito |
| Controller tests | HTTP validation, response contracts, and role-based access | MockMvc, Spring Security Test |
| Repository tests | Flyway schema, JPA mappings, queries, pagination, and constraints | PostgreSQL Testcontainers |
| Integration tests | Kafka events, transactional outbox relays, Feign behaviour, and persistence | Spring Boot, Kafka/PostgreSQL Testcontainers, WireMock |
| Platform smoke tests | Authenticated happy and failure paths across all services | Docker Compose, PowerShell |

Run the platform flows after starting Docker Compose:

```powershell
.\scripts\smoke-test.ps1
.\scripts\smoke-test.ps1 -PaymentStatus FAILED
```
