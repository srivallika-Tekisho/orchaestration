// Platform event types — the shared contract for Syntra's event system.
// Mirrors the DB: the envelope stored in event_outbox and the payloads
// registered in event_schemas (seeded by R__seed_event_schemas.sql).
//
// Plain TypeScript types (no runtime deps). Runtime validation, if needed,
// belongs in the relay/producer, not in this shared package.

// The 9 day-1 event types. Names must match event_schemas exactly —
// event_outbox has an FK to event_schemas, so an unregistered event_type
// cannot be published at all.
export const EVENT_TYPES = {
    JD_RECEIVED: "syntra.jd.received",
    JD_PARSED: "syntra.jd.parsed",
    RESUME_RECEIVED: "syntra.resume.received",
    PROFILE_PREPARED: "syntra.profile.prepared",
    DUPLICATE_REVIEW_REQUIRED: "syntra.duplicate.review_required",
    MATCH_COMPLETED: "syntra.match.completed",
    APPROVAL_REQUESTED: "syntra.approval.requested",
    APPROVAL_DECIDED: "syntra.approval.decided",
    AGENT_RUN_FAILED: "syntra.agent_run.failed",
  } as const;
  
  export type EventType = (typeof EVENT_TYPES)[keyof typeof EVENT_TYPES];
  
  // The envelope — identical for every event (the published / wire form).
  // event_outbox stores aggregate flat (aggregate_type + aggregate_id);
  // the relay composes the nested `aggregate` object when it publishes.
  export interface EventAggregate {
    type: string;
    id: string; // uuid
  }
  
  export interface EventEnvelope<TPayload = Record<string, unknown>> {
    event_id: string;
    event_type: EventType;
    schema_version: string;
    occurred_at: string; // ISO date-time
    correlation_id: string;
    causation_id: string | null;
    organization_id: string;
    aggregate: EventAggregate;
    payload_ref: TPayload;
    producer: string;
  }
  
  // Per-event payload types — mirror the JSON Schemas in the seed.
  export type ChannelType =
    | "EMAIL" | "LINKEDIN" | "DICE" | "MONSTER" | "INDEED"
    | "PORTAL" | "WHATSAPP" | "MANUAL" | "API";
  
  export interface JdReceivedPayload {
    requirement_id: string;
    ingestion_id?: string | null;
    jd_document_id?: string | null;
    channel_type?: ChannelType;
    priority?: "HOT" | "NORMAL" | "LOW";
    title?: string;
  }
  
  export interface JdParsedPayload {
    requirement_id: string;
    parser_version: string;
    agent_run_id?: string | null;
    mandatory_skill_count?: number;
    optional_skill_count?: number;
  }
  
  export interface ResumeReceivedPayload {
    document_id: string;
    candidate_id: string;
    sha256?: string;
    source?: "UPLOAD" | "EMAIL" | "CHANNEL" | "AGENT";
  }
  
  export interface ProfilePreparedPayload {
    candidate_id: string;
    candidate_profile_id: string;
    profile_version: number;
    parser_version?: string;
    embedding_model?: string;
    skill_count?: number;
    agent_run_id?: string | null;
  }
  
  export interface DuplicateReviewRequiredPayload {
    duplicate_review_id: string;
    candidate_a: string;
    candidate_b: string;
    approval_id?: string | null;
    agent_run_id?: string | null;
    signals?: {
      name_similarity?: number;
      embedding_similarity?: number;
      employer_overlap?: boolean;
      education_match?: boolean;
      [key: string]: unknown;
    };
  }
  
  export interface MatchCompletedPayload {
    match_job_id: string;
    requirement_id: string;
    agent_run_id?: string | null;
    policy_id?: string | null;
    result_count: number;
    top_score?: number | null;
    stats?: {
      retrieved?: number;
      deduped?: number;
      scored?: number;
      [key: string]: unknown;
    };
  }
  
  export interface ApprovalRequestedPayload {
    approval_id: string;
    agent_run_id: string;
    action_class: string;
    entity_type?: string | null;
    entity_id?: string | null;
    expires_at?: string | null;
  }
  
  export interface ApprovalDecidedPayload {
    approval_id: string;
    agent_run_id: string;
    decision: "APPROVED" | "MODIFIED" | "REJECTED" | "EXPIRED";
    decided_by?: string | null;
    decision_note?: string | null;
  }
  
  export interface AgentRunFailedPayload {
    agent_run_id: string;
    agent_name: string;
    error_code: string;
    error_message?: string | null;
    failed_node?: string | null;
    failed_step_seq?: number | null;
    attempts: number;
  }
  
  export interface EventPayloadMap {
    [EVENT_TYPES.JD_RECEIVED]: JdReceivedPayload;
    [EVENT_TYPES.JD_PARSED]: JdParsedPayload;
    [EVENT_TYPES.RESUME_RECEIVED]: ResumeReceivedPayload;
    [EVENT_TYPES.PROFILE_PREPARED]: ProfilePreparedPayload;
    [EVENT_TYPES.DUPLICATE_REVIEW_REQUIRED]: DuplicateReviewRequiredPayload;
    [EVENT_TYPES.MATCH_COMPLETED]: MatchCompletedPayload;
    [EVENT_TYPES.APPROVAL_REQUESTED]: ApprovalRequestedPayload;
    [EVENT_TYPES.APPROVAL_DECIDED]: ApprovalDecidedPayload;
    [EVENT_TYPES.AGENT_RUN_FAILED]: AgentRunFailedPayload;
  }
  
  export type PlatformEvent<T extends EventType = EventType> =
    T extends EventType
      ? EventEnvelope<EventPayloadMap[T]> & { event_type: T }
      : never;