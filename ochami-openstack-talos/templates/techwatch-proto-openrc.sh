#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PATH A — the simple way to authenticate (§1.4).
#
# Below this header the file is EXACTLY as Horizon generates it, at
#   Project → API Access → Download OpenStack RC File
# Download your own rather than reusing this copy: OS_USERNAME is per-person.
#
#   devbox$ source ~/techwatch-proto-openrc.sh     # prompts once, per shell
#   devbox$ openstack flavor list
#
# It authenticates as YOU, with your university password, carrying every role your
# account holds. Fine for the read-only work in §§1–2 and the quickest way to get
# moving. Switch to the application credential (path B,
# techwatch-proto-clouds.yaml) before §3 — the first section that CREATES
# anything — because that identity can be pinned to `member` and cannot be
# widened by a later role grant.
#
# ⚠ NEVER source this from ~/.bashrc, and never in a shell that also uses
#   clouds.yaml. openstacksdk MERGES OS_* environment variables on top of the
#   cloud OS_CLOUD selects rather than choosing between them, so mixing the two
#   produces errors that look like cloud faults but are purely local (§1.4).
#   If you have mixed them:
#     for v in $(env | sed -n 's/^\(OS_[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done
# ─────────────────────────────────────────────────────────────────────────────

# To use an OpenStack cloud you need to authenticate against the Identity
# service named keystone, which returns a **Token** and **Service Catalog**.
# The catalog contains the endpoints for all services the user/tenant has
# access to - such as Compute, Image Service, Identity, Object Storage, Block
# Storage, and Networking (code-named nova, glance, keystone, swift,
# cinder, and neutron).
#
# *NOTE*: Using the 3 *Identity API* does not necessarily mean any other
# OpenStack API is version 3. For example, your cloud provider may implement
# Image API v1.1, Block Storage API v2, and Compute API v2.0. OS_AUTH_URL is
# only for the Identity API served through keystone.
export OS_AUTH_URL=https://api.dl.acrc.bris.ac.uk:5000
# With the addition of Keystone we have standardized on the term **project**
# as the entity that owns the resources.
export OS_PROJECT_ID=c12540ed6a8b4d9991db1e1adaa4068b
export OS_PROJECT_NAME="techwatch-proto"
export OS_USER_DOMAIN_NAME="Default"
if [ -z "$OS_USER_DOMAIN_NAME" ]; then unset OS_USER_DOMAIN_NAME; fi
export OS_PROJECT_DOMAIN_ID="default"
if [ -z "$OS_PROJECT_DOMAIN_ID" ]; then unset OS_PROJECT_DOMAIN_ID; fi
# unset v2.0 items in case set
unset OS_TENANT_ID
unset OS_TENANT_NAME
# In addition to the owning entity (tenant), OpenStack stores the entity
# performing the action as the **user**.
export OS_USERNAME="tlangford"
# With Keystone you pass the keystone password.
echo "Please enter your OpenStack Password for project $OS_PROJECT_NAME as user $OS_USERNAME: "
read -sr OS_PASSWORD_INPUT
export OS_PASSWORD=$OS_PASSWORD_INPUT
# If your configuration has multiple regions, we set that information here.
# OS_REGION_NAME is optional and only valid in certain environments.
export OS_REGION_NAME="RegionOne"
# Don't leave a blank variable, unset it if it was empty
if [ -z "$OS_REGION_NAME" ]; then unset OS_REGION_NAME; fi
export OS_INTERFACE=public
export OS_IDENTITY_API_VERSION=3