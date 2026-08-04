-- R__seed_skills — starter skill taxonomy and aliases (design doc §6.5, §7.3)
-- =============================================================================
-- Deterministic taxonomy matching against these two tables produces the
-- mandatory-skill-coverage signal, which carries the largest single weight in
-- the scoring model (30%). An empty taxonomy does not degrade matching
-- gracefully — it zeroes out 40% of the score (mandatory + optional coverage)
-- and pushes everything onto semantic similarity. So this file is load-bearing,
-- not decoration.
--
-- SCOPE: a deliberately small starter set covering the US IT staffing skills
-- that show up in almost every JD. It is not a complete taxonomy and is not
-- meant to be maintained by hand at scale — the intended path is an admin
-- import (ESCO / O*NET / a licensed taxonomy) writing through the same tables.
-- What this file guarantees is that day-1 matching is not scoring against an
-- empty vocabulary.
--
-- SEED IDs ARE LITERAL AND FIXED, because candidate_skills, requirement_skills
-- and eval golden sets all reference skills.id. Ids increment in decimal within
-- the last group — hex letters are skipped so the sequence stays readable and
-- auditable by eye.
--
-- IDEMPOTENCY: conflict resolves on canonical_name / (organization_id, alias),
-- never on id, so re-running never renumbers a skill that rows already point at.
-- Recruiter- and LLM-contributed aliases are never touched (DO NOTHING).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Canonical skills
-- -----------------------------------------------------------------------------
INSERT INTO skills (id, canonical_name, category) VALUES
  -- Languages
  ('01900000-0000-7000-8000-000000000201', 'Java',                    'LANGUAGE'),
  ('01900000-0000-7000-8000-000000000202', 'Python',                  'LANGUAGE'),
  ('01900000-0000-7000-8000-000000000203', 'JavaScript',              'LANGUAGE'),
  ('01900000-0000-7000-8000-000000000204', 'TypeScript',              'LANGUAGE'),
  ('01900000-0000-7000-8000-000000000205', 'C#',                      'LANGUAGE'),
  ('01900000-0000-7000-8000-000000000206', 'Go',                      'LANGUAGE'),
  ('01900000-0000-7000-8000-000000000207', 'Ruby',                    'LANGUAGE'),
  ('01900000-0000-7000-8000-000000000208', 'PHP',                     'LANGUAGE'),
  ('01900000-0000-7000-8000-000000000209', 'Scala',                   'LANGUAGE'),
  ('01900000-0000-7000-8000-000000000210', 'Kotlin',                  'LANGUAGE'),

  -- Frameworks
  ('01900000-0000-7000-8000-000000000211', 'Spring Boot',             'FRAMEWORK'),
  ('01900000-0000-7000-8000-000000000212', 'React',                   'FRAMEWORK'),
  ('01900000-0000-7000-8000-000000000213', 'Angular',                 'FRAMEWORK'),
  ('01900000-0000-7000-8000-000000000214', 'Vue.js',                  'FRAMEWORK'),
  ('01900000-0000-7000-8000-000000000215', 'Node.js',                 'FRAMEWORK'),
  ('01900000-0000-7000-8000-000000000216', '.NET Core',               'FRAMEWORK'),
  ('01900000-0000-7000-8000-000000000217', 'Django',                  'FRAMEWORK'),
  ('01900000-0000-7000-8000-000000000218', 'Flask',                   'FRAMEWORK'),
  ('01900000-0000-7000-8000-000000000219', 'Express.js',              'FRAMEWORK'),
  ('01900000-0000-7000-8000-000000000220', 'Next.js',                 'FRAMEWORK'),

  -- Cloud and platform
  ('01900000-0000-7000-8000-000000000221', 'AWS',                     'CLOUD'),
  ('01900000-0000-7000-8000-000000000222', 'Microsoft Azure',         'CLOUD'),
  ('01900000-0000-7000-8000-000000000223', 'Google Cloud Platform',   'CLOUD'),
  ('01900000-0000-7000-8000-000000000224', 'Kubernetes',              'CLOUD'),
  ('01900000-0000-7000-8000-000000000225', 'Docker',                  'CLOUD'),
  ('01900000-0000-7000-8000-000000000226', 'Terraform',               'CLOUD'),
  ('01900000-0000-7000-8000-000000000227', 'Serverless',              'CLOUD'),

  -- Data engineering and analytics
  ('01900000-0000-7000-8000-000000000228', 'Apache Spark',            'DATA'),
  ('01900000-0000-7000-8000-000000000229', 'Apache Kafka',            'DATA'),
  ('01900000-0000-7000-8000-000000000230', 'Snowflake',               'DATA'),
  ('01900000-0000-7000-8000-000000000231', 'Databricks',              'DATA'),
  ('01900000-0000-7000-8000-000000000232', 'Apache Airflow',          'DATA'),
  ('01900000-0000-7000-8000-000000000233', 'dbt',                     'DATA'),
  ('01900000-0000-7000-8000-000000000234', 'Power BI',                'DATA'),

  -- Databases
  ('01900000-0000-7000-8000-000000000235', 'PostgreSQL',              'DATABASE'),
  ('01900000-0000-7000-8000-000000000236', 'MySQL',                   'DATABASE'),
  ('01900000-0000-7000-8000-000000000237', 'Oracle Database',         'DATABASE'),
  ('01900000-0000-7000-8000-000000000238', 'Microsoft SQL Server',    'DATABASE'),
  ('01900000-0000-7000-8000-000000000239', 'MongoDB',                 'DATABASE'),
  ('01900000-0000-7000-8000-000000000240', 'Redis',                   'DATABASE'),
  ('01900000-0000-7000-8000-000000000241', 'Elasticsearch',           'DATABASE'),

  -- DevOps
  ('01900000-0000-7000-8000-000000000242', 'Jenkins',                 'DEVOPS'),
  ('01900000-0000-7000-8000-000000000243', 'GitLab CI',               'DEVOPS'),
  ('01900000-0000-7000-8000-000000000244', 'GitHub Actions',          'DEVOPS'),
  ('01900000-0000-7000-8000-000000000245', 'Ansible',                 'DEVOPS'),
  ('01900000-0000-7000-8000-000000000246', 'Linux',                   'DEVOPS'),

  -- Testing
  ('01900000-0000-7000-8000-000000000247', 'Selenium',                'TESTING'),
  ('01900000-0000-7000-8000-000000000248', 'Cypress',                 'TESTING'),
  ('01900000-0000-7000-8000-000000000249', 'JUnit',                   'TESTING'),

  -- Domains. These feed the 10% domain/role-relevance weight in §7.3, which is
  -- why they live in the same taxonomy rather than in a separate enum: the JD
  -- says "healthcare experience required" in the same sentence as its languages.
  ('01900000-0000-7000-8000-000000000250', 'Healthcare',              'DOMAIN'),
  ('01900000-0000-7000-8000-000000000251', 'Financial Services',      'DOMAIN'),
  ('01900000-0000-7000-8000-000000000252', 'Insurance',               'DOMAIN'),
  ('01900000-0000-7000-8000-000000000253', 'Telecom',                 'DOMAIN')

ON CONFLICT (canonical_name) DO UPDATE
  SET category = EXCLUDED.category
  WHERE skills.category IS DISTINCT FROM EXCLUDED.category;


-- -----------------------------------------------------------------------------
-- Every canonical name is also an alias
-- -----------------------------------------------------------------------------
-- normalize_skills resolves through skill_aliases first and calls the LLM only
-- on a miss. If canonical names were absent from the alias table, the exact
-- string "PostgreSQL" straight out of a JD would miss and burn an LLM call, so
-- the taxonomy-first design would degrade to LLM-first for the commonest case.
--
-- Driven off `skills` rather than a literal list so that admin-imported skills
-- pick this up on the next run too. alias is citext, so this covers every
-- capitalisation variant of the canonical form.
INSERT INTO skill_aliases (id, organization_id, alias, skill_id, source)
SELECT gen_random_uuid(), NULL, s.canonical_name, s.id, 'SEED'
FROM skills s
ON CONFLICT ON CONSTRAINT skill_aliases_org_alias_key DO NOTHING;


-- -----------------------------------------------------------------------------
-- Surface-form aliases
-- -----------------------------------------------------------------------------
-- Joined to skills by canonical_name rather than repeating the uuids, so a
-- transposed digit cannot quietly point an alias at the wrong skill.
--
-- Some mappings are deliberately lossy in the direction that helps a recruiter:
-- 'mariadb' -> MySQL, 'eks' -> Kubernetes, 'spring' -> Spring Boot. A JD asking
-- for MariaDB is satisfied by a MySQL consultant far more often than not, and
-- the alternative — a miss — drops the skill from coverage entirely.
--
-- Ambiguous short forms are deliberately EXCLUDED. 'lambda' is not an alias for
-- Serverless because it is also a Java language feature, and 'iac' is not an
-- alias for Terraform. A wrong alias is worse than a miss: a miss falls through
-- to the LLM, a wrong alias is silently authoritative.
INSERT INTO skill_aliases (id, organization_id, alias, skill_id, source)
SELECT gen_random_uuid(), NULL, a.alias, s.id, 'SEED'
FROM (VALUES
  -- Languages
  ('core java',              'Java'),
  ('java se',                'Java'),
  ('j2se',                   'Java'),
  ('jdk',                    'Java'),
  ('python3',                'Python'),
  ('py',                     'Python'),
  ('js',                     'JavaScript'),
  ('ecmascript',             'JavaScript'),
  ('es6',                    'JavaScript'),
  ('vanilla js',             'JavaScript'),
  ('ts',                     'TypeScript'),
  ('csharp',                 'C#'),
  ('c sharp',                'C#'),
  ('c-sharp',                'C#'),
  ('golang',                 'Go'),
  ('go lang',                'Go'),
  ('php7',                   'PHP'),
  ('php8',                   'PHP'),

  -- Frameworks
  ('springboot',             'Spring Boot'),
  ('spring-boot',            'Spring Boot'),
  ('spring',                 'Spring Boot'),
  ('spring framework',       'Spring Boot'),
  ('spring mvc',             'Spring Boot'),
  ('reactjs',                'React'),
  ('react.js',               'React'),
  ('react js',               'React'),
  ('react hooks',            'React'),
  ('angularjs',              'Angular'),
  ('angular.js',             'Angular'),
  ('angular js',             'Angular'),
  ('angular 2+',             'Angular'),
  ('vue',                    'Vue.js'),
  ('vuejs',                  'Vue.js'),
  ('vue js',                 'Vue.js'),
  ('node',                   'Node.js'),
  ('nodejs',                 'Node.js'),
  ('node js',                'Node.js'),
  ('.net',                   '.NET Core'),
  ('dotnet',                 '.NET Core'),
  ('dotnet core',            '.NET Core'),
  ('net core',               '.NET Core'),
  ('asp.net core',           '.NET Core'),
  ('django rest framework',  'Django'),
  ('drf',                    'Django'),
  ('express',                'Express.js'),
  ('expressjs',              'Express.js'),
  ('nextjs',                 'Next.js'),
  ('next js',                'Next.js'),

  -- Cloud
  ('amazon web services',    'AWS'),
  ('aws cloud',              'AWS'),
  ('azure',                  'Microsoft Azure'),
  ('ms azure',               'Microsoft Azure'),
  ('gcp',                    'Google Cloud Platform'),
  ('google cloud',           'Google Cloud Platform'),
  ('k8s',                    'Kubernetes'),
  ('eks',                    'Kubernetes'),
  ('aks',                    'Kubernetes'),
  ('gke',                    'Kubernetes'),
  ('containerization',       'Docker'),
  ('containers',             'Docker'),
  ('aws lambda',             'Serverless'),
  ('azure functions',        'Serverless'),

  -- Data
  ('spark',                  'Apache Spark'),
  ('pyspark',                'Apache Spark'),
  ('spark sql',              'Apache Spark'),
  ('kafka',                  'Apache Kafka'),
  ('confluent kafka',        'Apache Kafka'),
  ('snowflake dw',           'Snowflake'),
  ('airflow',                'Apache Airflow'),
  ('data build tool',        'dbt'),
  ('powerbi',                'Power BI'),
  ('power-bi',               'Power BI'),

  -- Databases
  ('postgres',               'PostgreSQL'),
  ('psql',                   'PostgreSQL'),
  ('postgre sql',            'PostgreSQL'),
  ('my sql',                 'MySQL'),
  ('mariadb',                'MySQL'),
  ('oracle',                 'Oracle Database'),
  ('oracle db',              'Oracle Database'),
  ('plsql',                  'Oracle Database'),
  ('pl/sql',                 'Oracle Database'),
  ('sql server',             'Microsoft SQL Server'),
  ('mssql',                  'Microsoft SQL Server'),
  ('ms sql',                 'Microsoft SQL Server'),
  ('t-sql',                  'Microsoft SQL Server'),
  ('tsql',                   'Microsoft SQL Server'),
  ('mongo',                  'MongoDB'),
  ('mongo db',               'MongoDB'),
  ('redis cache',            'Redis'),
  ('elastic search',         'Elasticsearch'),
  ('elk',                    'Elasticsearch'),
  ('elk stack',              'Elasticsearch'),
  ('opensearch',             'Elasticsearch'),

  -- DevOps
  ('jenkins ci',             'Jenkins'),
  ('jenkins pipeline',       'Jenkins'),
  ('gitlab',                 'GitLab CI'),
  ('gitlab-ci',              'GitLab CI'),
  ('gitlab pipelines',       'GitLab CI'),
  ('gh actions',             'GitHub Actions'),
  ('github workflow',        'GitHub Actions'),
  ('unix',                   'Linux'),
  ('rhel',                   'Linux'),
  ('ubuntu',                 'Linux'),

  -- Testing
  ('selenium webdriver',     'Selenium'),
  ('webdriver',              'Selenium'),
  ('cypress.io',             'Cypress'),
  ('junit5',                 'JUnit'),
  ('junit 5',                'JUnit'),

  -- Domains
  ('healthcare it',          'Healthcare'),
  ('healthcare domain',      'Healthcare'),
  ('hipaa',                  'Healthcare'),
  ('ehr',                    'Healthcare'),
  ('fintech',                'Financial Services'),
  ('banking',                'Financial Services'),
  ('capital markets',        'Financial Services'),
  ('bfsi',                   'Financial Services'),
  ('insurtech',              'Insurance'),
  ('p&c insurance',          'Insurance'),
  ('telecommunications',     'Telecom'),
  ('telco',                  'Telecom')
) AS a (alias, canonical_name)
JOIN skills s ON s.canonical_name = a.canonical_name
ON CONFLICT ON CONSTRAINT skill_aliases_org_alias_key DO NOTHING;


-- -----------------------------------------------------------------------------
-- Assertion
-- -----------------------------------------------------------------------------
-- Every alias above is written as a literal canonical_name. A typo there makes
-- the JOIN drop the row silently and the alias simply never exists — no error,
-- just a permanently missing lookup that shows up months later as a skill the
-- matcher "never seems to find". Count the rows that survived.
DO $$
DECLARE
  seeded_aliases int;
  canonical      int;
BEGIN
  SELECT count(*) INTO canonical FROM skills;

  SELECT count(*) INTO seeded_aliases
  FROM skill_aliases
  WHERE organization_id IS NULL AND source = 'SEED';

  -- 53 canonical names + 120 surface forms. Adjust when the seed grows; the
  -- point of the hard number is that a silently dropped JOIN row fails here.
  IF seeded_aliases < canonical + 120 THEN
    RAISE EXCEPTION
      'Expected at least % platform SEED aliases (% canonical + 120 surface '
      'forms) but found %. A canonical_name literal in the surface-form list '
      'most likely does not match any row in skills.',
      canonical + 120, canonical, seeded_aliases;
  END IF;

  RAISE NOTICE 'Skill taxonomy: % canonical skills, % platform aliases.',
    canonical, seeded_aliases;
END
$$;


-- =============================================================================