-- Review before running: this enables anonymous uploads/deletes for a public bucket.
-- It matches the current app model (no auth) for photo attachments.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'ot-record-photos',
  'ot-record-photos',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

do $policies$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'Public can upload OT photos'
  ) then
    execute $sql$
      create policy "Public can upload OT photos"
      on storage.objects
      for insert
      to public
      with check (bucket_id = 'ot-record-photos')
    $sql$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'Public can delete OT photos'
  ) then
    execute $sql$
      create policy "Public can delete OT photos"
      on storage.objects
      for delete
      to public
      using (bucket_id = 'ot-record-photos')
    $sql$;
  end if;
end
$policies$;
