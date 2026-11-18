# Professional referrals, organised

## Context

The original product brief came from a New York Jewish community where finding a specialist often began with a personal introduction. This is the context of one client's request, not a generalisation about a population. The intended service would give those existing relationships a searchable digital structure.

## Problem

Skills and availability were scattered across conversations and group chats. A person looking for a specialist had to repeat a request and manually ask who knew a suitable candidate. Community organisers had no single view of participants and hiring needs.

## Solution

A Flutter application combines offered/sought skills, professional profiles, name/skill search, mutual contacts, direct text conversations and a shared Hiring feed. Invitations support network growth. Administrative roles support managed profiles and community operation.

## Value for both sides

Organisers can structure a directory, manage profiles and coordinate hiring requests. Members can describe their expertise, discover relevant people and start a conversation with the context of a mutual contact. No hiring or revenue improvement is claimed without measured evidence.

## Engineering

One Dart codebase targets Android, iOS and a separate browser preview. Controllers and repositories separate interface state from persistence and platform operations. Supabase implements Auth, PostgreSQL, Storage, Realtime and server functions; Firebase supplies native messaging integration. Operation identifiers, durable journals, field-level profile merges and cleanup workers address retries, interrupted sessions and data lifecycle.

## Working method

Requirements were mapped to screen groups, divided into scoped issues, implemented in focused branches and reviewed through pull requests. Local tests and builds were recorded separately from human acceptance. Original repository history is retained.

## Result and limits

The working source, a standalone fictional-data demonstration, Android demo APK and iOS build instructions are available publicly. The original client project stopped before public store distribution. Native provider/device acceptance and store publication are not claimed.

[Try online](https://shteinyr-community-network.web.app) · [Read the source](https://github.com/Shteinyr/paul-flutter-prototype) · [Screenshots](media/README.md)
