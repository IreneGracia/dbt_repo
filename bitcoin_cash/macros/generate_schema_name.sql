-- Use the configured +schema (staging / mart) as the dataset name directly,
-- instead of dbt's default <target_schema>_<custom_schema> concatenation. This
-- makes models land in the existing `staging` / `mart` datasets that Terraform
-- created.

{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
