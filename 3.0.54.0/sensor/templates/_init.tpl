{{/*
    srox.init $

    Initialization template for the internal data structures.
    This template is designed to be included in every template file, but will only be executed
    once by leveraging state sharing between templates.
   */}}
{{ define "srox.init" }}

{{ $ := . }}

{{/*
    On first(!) instantiation, set up the $._rox structure, containing everything required by
    the resource template files.
   */}}
{{ if not $._rox }}

{{/*
    Calculate the fingerprint of the input config.
   */}}
{{ $configFP := printf "%s-%d" (.Values | toJson | sha256sum) .Release.Revision }}

{{/*
    Initial Setup
   */}}

{{ $values := deepCopy $.Values }}
{{ include "srox.applyCompatibilityTranslation" (list $ $values) }}

{{/*
    $rox / ._rox is the dictionary in which _all_ data that is modified by the init logic
    is stored.
    We ensure that it has the required shape, and then right after merging the user-specified
    $.Values, we apply some bootstrap defaults.
   */}}
{{ $rox := deepCopy $values }}
{{ $_ := include "srox.mergeInto" (list $rox ($.Files.Get "internal/config-shape.yaml" | fromYaml) ($.Files.Get "internal/bootstrap-defaults.yaml" | fromYaml)) }}
{{ $_ = set $ "_rox" $rox }}

{{/* Set the config fingerprint */}}
{{ $_ = set $._rox "_configFP" $configFP }}

{{/* Global state (accessed from sub-templates) */}}
{{ $state := dict "notes" list "warnings" list "referencedImages" dict }}
{{ $_ = set $._rox "_state" $state }}

{{/*
    General validation (before merging in defaults).
   */}}


{{ $_ = set $._rox "_namespace" "stackrox" }}


{{ if ne $._rox._namespace "stackrox" }}
  {{ if $._rox.allowNonstandardNamespace }}
    {{ include "srox.note" (list $ (printf "You have chosen to deploy to namespace '%s'." $._rox._namespace)) }}
  {{ else }}
    {{ include "srox.fail" (printf "You have chosen to deploy to namespace '%s', not 'stackrox'. If this was accidental, please re-run helm with the '-n stackrox' option. Otherwise, if you need to deploy into this namespace, set the 'allowNonstandardNamespace' configuration value to true." $._rox._namespace) }}
  {{ end }}
{{ end }}



{{/*
    API Server setup. The problem with `.Capabilities.APIVersions` is that Helm does not
    allow setting overrides for those when using `helm template` or `--dry-run`. Thus,
    if we rely on `.Capabilities.APIVersions` directly, we lose flexibility for our chart
    in these settings. Therefore, we use custom fields such that a user in principle has
    the option to inject via `--set`/`-f` everything we rely upon.
   */}}
{{ $apiResources := list }}
{{ if not (kindIs "invalid" $._rox.meta.apiServer.overrideAPIResources) }}
  {{ $apiResources = $._rox.meta.apiServer.overrideAPIResources }}
{{ else }}
  {{ range $apiResource := $.Capabilities.APIVersions }}
    {{ $apiResources = append $apiResources $apiResource }}
  {{ end }}
{{ end }}
{{ if $._rox.meta.apiServer.extraAPIResources }}
  {{ $apiResources = concat $apiResources $._rox.meta.apiServer.extraAPIResources }}
{{ end }}
{{ $apiServerVersion := coalesce $._rox.meta.apiServer.version $.Capabilities.KubeVersion.Version }}
{{ $apiServer := dict "apiResources" $apiResources "version" $apiServerVersion }}
{{ $_ = set $._rox "_apiServer" $apiServer }}


{{/*
    Environment setup - part 1
   */}}
{{ $env := $._rox.env }}

{{/* Infer OpenShift, if needed */}}
{{ if kindIs "invalid" $env.openshift }}
  {{ $_ := set $env "openshift" (has "apps.openshift.io/v1" $._rox._apiServer.apiResources) }}
  {{ if $env.openshift }}
    {{ include "srox.note" (list $ "Based on API server properties, we have inferred that you are deploying into an OpenShift cluster. Set the `env.openshift` property explicitly to false/true to override the auto-sensed value.") }}
  {{ end }}
{{ end }}

{{/* Infer Istio, if needed */}}
{{ if kindIs "invalid" $env.istio }}
  {{ $_ := set $env "istio" (has "networking.istio.io/v1alpha3" $._rox._apiServer.apiResources) }}
  {{ if $env.istio }}
    {{ include "srox.note" (list $ "Based on API server properties, we have inferred that you are deploying into an Istio-enabled cluster. Set the `env.istio` property explicitly to false/true to override the auto-sensed value.") }}
  {{ end }}
{{ end }}

{{/* Apply default for slim collector mode */}}
{{ if kindIs "invalid" $._rox.collector.slimMode }}
  {{ include "srox.warn" (list $ "You have not specified whether or not to use a slim collector image, therefore defaulting to using the full image. If your StackRox Central deployment has access to the internet or current collector support packages, we strongly recommend setting this option to true, as it may drastically decrease your image pull traffic.") }}
  {{ $_ = set $._rox.collector "slimMode" false }}
{{ end }}

{{/* Adjust collector image pull policy based on slim/non-slim mode */}}
{{ if kindIs "invalid" $._rox.image.collector.pullPolicy }}
  {{ if $._rox.collector.slimMode }}
    {{ $_ = set $._rox.image.collector "pullPolicy" "IfNotPresent" }}
  {{ else }}
    {{ $_ = set $._rox.image.collector "pullPolicy" "Always" }}
  {{ end }}
{{ end }}

{{/* Apply defaults */}}
{{ $defaultsCfg := dict }}
{{ $_ = include "srox.mergeInto" (list $defaultsCfg (tpl ($.Files.Get "internal/defaults.yaml") . | fromYaml)) }}
{{ $_ = set $rox "_defaults" $defaultsCfg }}
{{ $_ = include "srox.mergeInto" (list $rox $defaultsCfg.defaults) }}

{{/* Expand applicable config values */}}
{{ $expandables := $.Files.Get "internal/expandables.yaml" | fromYaml }}
{{ include "srox.expandAll" (list $ $rox $expandables) }}

{{ if kindIs "invalid" ._rox.image.main.registry }}
  {{ $_ = set $._rox.image.main "registry" $._rox.image.registry }}
{{ end }}

{{/* Adjust image tag settings */}}
{{ if or $._rox.image.collector.tag $._rox.image.collector.fullRef }}
  {{ include "srox.warn" (list $ "You have specified an explicit collector image tag. This will prevent the collector image from being updated correctly when upgrading to a newer version of this chart.") }}
  {{ if not (kindIs "invalid" $._rox.collector.slimMode) }}
    {{ include "srox.warn" (list $ "You have specified an explicit collector image tag. The slim collector setting will not have any effect.") }}
  {{ end }}
{{ else }}
  {{ $_ = set $._rox.image.collector "_abbrevImageRef" (printf "%s/%s" $._rox.image.collector.registry $._rox.image.collector.name) }}
  {{ if $._rox.collector.slimMode }}
    {{ $_ = set $._rox.image.collector "tag" "3.1.10-slim" }}
  {{ else }}
    {{ $_ = set $._rox.image.collector "tag" "3.1.10-latest" }}
  {{ end }}
{{ end }}

{{ if or $._rox.image.main.tag $._rox.image.main.fullRef }}
  {{ include "srox.warn" (list $ "You have specified an explicit main image tag. This will prevent the main image from being updated correctly when upgrading to a newer version of this chart.") }}
{{ else }}
  {{ $_ = set $._rox.image.main "tag" "3.0.54.0" }}
  {{ $_ = set $._rox.image.main "_abbrevImageRef" (printf "%s/%s" $._rox.image.main.registry $._rox.image.main.name) }}
{{ end }}

{{/* Initial image pull secret setup. */}}
{{ include "srox.mergeInto" (list $._rox.mainImagePullSecrets $._rox.imagePullSecrets) }}
{{ include "srox.configureImagePullSecrets" (list $ "mainImagePullSecrets" $._rox.mainImagePullSecrets (list "stackrox")) }}
{{ include "srox.mergeInto" (list $._rox.collectorImagePullSecrets $._rox.imagePullSecrets) }}
{{ include "srox.configureImagePullSecrets" (list $ "collectorImagePullSecrets" $._rox.collectorImagePullSecrets (list "stackrox" "collector-stackrox")) }}

{{/* Additional CAs. */}}
{{ $additionalCAs := deepCopy $._rox.additionalCAs }}
{{ range $path, $content := .Files.Glob "secrets/additional-cas/**" }}
  {{ $content = toString $content }}
  {{ $name := base $path }}
  {{ if and (hasKey $additionalCAs $name) }}
    {{ if not (eq $content (index $additionalCAs $name)) }}
      {{ include "srox.fail" (printf "Additional CA certificate named %q is specified in 'additionalCAs' and exists as file %q at the same time. Delete or rename one of these certificate." $name $path) }}
    {{ end }}
  {{ end }}
  {{ $_ = set $additionalCAs $name $content }}
{{ end }}
{{ $_ = set $._rox "_additionalCAs" $additionalCAs }}

{{/*
    Final validation (after merging in defaults).
   */}}

{{ if eq ._rox.clusterName "" }}
  {{ include "srox.fail" "No cluster name specified. Set 'clusterName' to the desired cluster name." }}
{{ end}}

{{/* Image settings */}}
{{ include "srox.configureImage" (list $ ._rox.image.main) }}
{{ include "srox.configureImage" (list $ ._rox.image.collector) }}

{{/*
    Post-processing steps.
   */}}

{{ include "srox.configureImagePullSecretsForDockerRegistry" (list $ ._rox.mainImagePullSecrets) }}
{{ include "srox.configureImagePullSecretsForDockerRegistry" (list $ ._rox.collectorImagePullSecrets) }}

{{ end }}

{{ end }}
