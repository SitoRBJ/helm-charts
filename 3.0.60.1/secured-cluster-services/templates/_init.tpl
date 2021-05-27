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
{{ $_ := include "srox.mergeInto" (list $rox ($.Files.Get "internal/config-shape.yaml" | fromYaml)) }}
{{ $_ = set $ "_rox" $rox }}

{{/* Set the config fingerprint */}}
{{ $_ = set $._rox "_configFP" $configFP }}

{{/* Global state (accessed from sub-templates) */}}
{{ $state := dict "notes" list "warnings" list "referencedImages" dict }}
{{ $_ = set $._rox "_state" $state }}

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

{{ include "srox.applyDefaults" $ }}

{{/* Expand applicable config values */}}
{{ $expandables := $.Files.Get "internal/expandables.yaml" | fromYaml }}
{{ include "srox.expandAll" (list $ $rox $expandables) }}

{{/*
    General validation of effective settings.
   */}}

{{ if not $.Release.IsUpgrade }}
{{ if ne $._rox._namespace "stackrox" }}
  {{ if $._rox.allowNonstandardNamespace }}
    {{ include "srox.note" (list $ (printf "You have chosen to deploy to namespace '%s'." $._rox._namespace)) }}
  {{ else }}
    {{ include "srox.fail" (printf "You have chosen to deploy to namespace '%s', not 'stackrox'. If this was accidental, please re-run helm with the '-n stackrox' option. Otherwise, if you need to deploy into this namespace, set the 'allowNonstandardNamespace' configuration value to true." $._rox._namespace) }}
  {{ end }}
{{ end }}
{{ end }}

{{/* If a cluster name should change the confirmNewClusterName value must match clusterName. */}}
{{ if and $._rox.confirmNewClusterName (ne $._rox.confirmNewClusterName $._rox.clusterName) }}
    {{ include "srox.fail"  (printf "Failed to change cluster name. Values for confirmNewClusterName '%s' did not match clusterName '%s'." $._rox.confirmNewClusterName $._rox.clusterName) }}
{{ end }}


{{ if not $.Release.IsUpgrade }}
{{ if ne $.Release.Name $.Chart.Name }}
  {{ if $._rox.allowNonstandardReleaseName }}
    {{ include "srox.warn" (list $ (printf "You have chosen a release name of '%s', not '%s'. Accompanying scripts and commands in documentation might require adjustments." $.Release.Name $.Chart.Name)) }}
  {{ else }}
    {{ include "srox.fail" (printf "You have chosen a release name of '%s', not '%s'. We strongly recommend using the standard release name. If you must use a different name, set the 'allowNonstandardReleaseName' configuration option to true." $.Release.Name $.Chart.Name) }}
  {{ end }}
{{ end }}
{{ end }}



{{/*
   Environment setup
*/}}

{{/* Infer openshift version */}}
{{ if and $._rox.env.openshift (kindIs "bool" $._rox.env.openshift) }}
  {{/* Parse and add KubeVersion as semver from built-in resources. This is necessary to compare valid integer numbers. */}}
  {{ $kubeVersion := semver .Capabilities.KubeVersion.Version }}

  {{/* Default to OpenShift 3 if no openshift resources are available, i.e. in helm tempalte commands */}}
  {{ if not (has "apps.openshift.io/v1" $._rox._apiServer.apiResources) }}
    {{ $_ := set $._rox.env "openshift" 3 }}
  {{ else if gt $kubeVersion.Minor 11 }}
    {{ $_ := set $._rox.env "openshift" 4 }}
  {{ else }}
    {{ $_ := set $._rox.env "openshift" 3 }}
  {{ end }}

  {{ include "srox.note" (list $ (printf "Based on API server properties, we have inferred that you are deploying into an OpenShift %d cluster. Set the `env.openshift` property explicitly to 3 or 4 to override the auto-sensed value." $._rox.env.openshift)) }}
{{ end }}
{{ if not (kindIs "bool" $._rox.env.openshift) }}
  {{ $_ := set $._rox.env "openshift" (int $._rox.env.openshift) }}
{{ else if not $._rox.env.openshift }}
  {{ $_ := set $._rox.env "openshift" 0 }}
{{ end }}

{{ if and $._rox.admissionControl.dynamic.enforceOnCreates (not $._rox.admissionControl.listenOnCreates) }}
  {{ include "srox.warn" (list $ "Incompatible settings: 'admissionControl.dynamic.enforceOnCreates' is set to true, while `admissionControl.listenOnCreates` is set to false. For the feature to be active, enable both settings by setting them to true.") }}
{{ end }}

{{ if and $._rox.admissionControl.dynamic.enforceOnUpdates (not $._rox.admissionControl.listenOnUpdates) }}
  {{ include "srox.warn" (list $ "Incompatible settings: 'admissionControl.dynamic.enforceOnUpdates' is set to true, while `admissionControl.listenOnUpdates` is set to false. For the feature to be active, enable both settings by setting them to true.") }}
{{ end }}

{{ if and (eq $._rox.env.openshift 3) $._rox.admissionControl.listenOnEvents }}
  {{ include "srox.fail" "'admissionControl.listenOnEvents' is set to true, but the chart is being deployed in OpenShift 3.x compatibility mode, which does not work with this feature. Set 'env.openshift' to '4' in order to enable OpenShift 4.x features." }}
{{ end }}

{{/* Initial image pull secret setup. */}}
{{ include "srox.mergeInto" (list $._rox.mainImagePullSecrets $._rox.imagePullSecrets) }}
{{ include "srox.configureImagePullSecrets" (list $ "mainImagePullSecrets" $._rox.mainImagePullSecrets "secured-cluster-services-main" (list "stackrox") $._rox._namespace) }}
{{ include "srox.mergeInto" (list $._rox.collectorImagePullSecrets $._rox.imagePullSecrets) }}
{{ include "srox.configureImagePullSecrets" (list $ "collectorImagePullSecrets" $._rox.collectorImagePullSecrets "secured-cluster-services-collector" (list "stackrox" "collector-stackrox") $._rox._namespace) }}

{{/* Additional CAs. */}}
{{ $additionalCAList := list }}
{{ if kindIs "string" $._rox.additionalCAs }}
  {{ if $._rox.additionalCAs }}
    {{ $additionalCAList = append $additionalCAList (dict "name" "ca.crt" "contents" $._rox.additionalCAs) }}
  {{ end }}
{{ else if kindIs "slice" $._rox.additionalCAs }}
  {{ range $contents := $._rox.additionalCAs }}
    {{ $additionalCAList = append $additionalCAList (dict "name" "ca.crt" "contents" $contents) }}
  {{ end }}
{{ else if kindIs "map" $._rox.additionalCAs }}
  {{ range $name := keys $._rox.additionalCAs | sortAlpha }}
    {{ $additionalCAList = append $additionalCAList (dict "name" $name "contents" (get $._rox.additionalCAs $name)) }}
  {{ end }}
{{ else if not (kindIs "invalid" $._rox.additionalCAs) }}
  {{ include "srox.fail" (printf "Invalid kind %s for additionalCAs" (kindOf $._rox.additionalCAs)) }}
{{ end }}
{{ range $path, $contents := .Files.Glob "secrets/additional-cas/**" }}
  {{ $name := trimPrefix "secrets/additional-cas/" $path }}
  {{ $additionalCAList = append $additionalCAList (dict "name" $name "contents" (toString $contents)) }}
{{ end }}
{{ $additionalCAs := dict }}
{{ range $idx, $elem := $additionalCAList }}
  {{ if not (kindIs "string" $elem.contents) }}
    {{ include "srox.fail" (printf "Invalid non-string contents kind %s at index %d (%q) of additionalCAs" (kindOf $elem.contents) $idx $elem.name) }}
  {{ end }}
  {{/* In a k8s secret, no characters other than alphanumeric, '.', '_' and '-' are allowed. Also, for the
       update-ca-certificates script to work, the file names must end in '.crt'. */}}

  {{ $normalizedName := printf "%02d-%s.crt" $idx (regexReplaceAll "[^[:alnum:]._-]" $elem.name "-" | trimSuffix ".crt") }}
  {{ $_ := set $additionalCAs $normalizedName $elem.contents }}
{{ end }}
{{ $_ = set $._rox "_additionalCAs" $additionalCAs }}

{{/*
    Final validation (after merging in defaults).
   */}}

{{ if and ._rox.helmManaged (not ._rox.clusterName) }}
  {{ include "srox.fail" "No cluster name specified. Set 'clusterName' to the desired cluster name." }}
{{ end }}

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
