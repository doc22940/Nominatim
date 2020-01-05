-- Functions for address interpolation objects in location_property_osmline.

-- Splits the line at the given point and returns the two parts
-- in a multilinestring.
CREATE OR REPLACE FUNCTION split_line_on_node(line GEOMETRY, point GEOMETRY)
RETURNS GEOMETRY
  AS $$
BEGIN
  RETURN ST_Split(ST_Snap(line, point, 0.0005), point);
END;
$$
LANGUAGE plpgsql IMMUTABLE;


-- find the parent road of the cut road parts
CREATE OR REPLACE FUNCTION get_interpolation_parent(wayid BIGINT, street TEXT,
                                                    place TEXT, partition INTEGER,
                                                    centroid GEOMETRY, geom GEOMETRY)
  RETURNS BIGINT
  AS $$
DECLARE
  addr_street TEXT;
  addr_place TEXT;
  parent_place_id BIGINT;
  address_street_word_ids INTEGER[];

  waynodes BIGINT[];

  location RECORD;
BEGIN
  addr_street = street;
  addr_place = place;

  IF addr_street is null and addr_place is null THEN
    select nodes from planet_osm_ways where id = wayid INTO waynodes;
    FOR location IN SELECT placex.address from placex
                    where osm_type = 'N' and osm_id = ANY(waynodes)
                          and placex.address is not null
                          and (placex.address ? 'street' or placex.address ? 'place')
                          and indexed_status < 100
                    limit 1 LOOP
      addr_street = location.address->'street';
      addr_place = location.address->'place';
    END LOOP;
  END IF;

  IF addr_street IS NOT NULL THEN
    address_street_word_ids := get_name_ids(make_standard_name(addr_street));
    IF address_street_word_ids IS NOT NULL THEN
      FOR location IN SELECT place_id from getNearestNamedRoadFeature(partition, centroid, address_street_word_ids) LOOP
        parent_place_id := location.place_id;
      END LOOP;
    END IF;
  END IF;

  IF parent_place_id IS NULL AND addr_place IS NOT NULL THEN
    address_street_word_ids := get_name_ids(make_standard_name(addr_place));
    IF address_street_word_ids IS NOT NULL THEN
      FOR location IN SELECT place_id from getNearestNamedPlaceFeature(partition, centroid, address_street_word_ids) LOOP
        parent_place_id := location.place_id;
      END LOOP;
    END IF;
  END IF;

  IF parent_place_id is null THEN
    FOR location IN SELECT place_id FROM placex
        WHERE ST_DWithin(geom, placex.geometry, 0.001) and placex.rank_search = 26
        ORDER BY (ST_distance(placex.geometry, ST_LineInterpolatePoint(geom,0))+
                  ST_distance(placex.geometry, ST_LineInterpolatePoint(geom,0.5))+
                  ST_distance(placex.geometry, ST_LineInterpolatePoint(geom,1))) ASC limit 1
    LOOP
      parent_place_id := location.place_id;
    END LOOP;
  END IF;

  IF parent_place_id is null THEN
    RETURN 0;
  END IF;

  RETURN parent_place_id;
END;
$$
LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION osmline_reinsert(node_id BIGINT, geom GEOMETRY)
  RETURNS BOOLEAN
  AS $$
DECLARE
  existingline RECORD;
BEGIN
   SELECT w.id FROM planet_osm_ways w, location_property_osmline p
     WHERE p.linegeo && geom and p.osm_id = w.id and p.indexed_status = 0
           and node_id = any(w.nodes) INTO existingline;

   IF existingline.id is not NULL THEN
       DELETE FROM location_property_osmline WHERE osm_id = existingline.id;
       INSERT INTO location_property_osmline (osm_id, address, linegeo)
         SELECT osm_id, address, geometry FROM place
           WHERE osm_type = 'W' and osm_id = existingline.id;
   END IF;

   RETURN true;
END;
$$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION osmline_insert()
  RETURNS TRIGGER
  AS $$
BEGIN
  NEW.place_id := nextval('seq_place');
  NEW.indexed_date := now();

  IF NEW.indexed_status IS NULL THEN
      IF NEW.address is NULL OR NOT NEW.address ? 'interpolation'
         OR NEW.address->'interpolation' NOT IN ('odd', 'even', 'all') THEN
          -- other interpolation types than odd/even/all (e.g. numeric ones) are not supported
          RETURN NULL;
      END IF;

      NEW.indexed_status := 1; --STATUS_NEW
      NEW.country_code := lower(get_country_code(NEW.linegeo));

      NEW.partition := get_partition(NEW.country_code);
      NEW.geometry_sector := geometry_sector(NEW.partition, NEW.linegeo);
  END IF;

  RETURN NEW;
END;
$$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION osmline_update()
  RETURNS TRIGGER
  AS $$
DECLARE
  place_centroid GEOMETRY;
  waynodes BIGINT[];
  prevnode RECORD;
  nextnode RECORD;
  startnumber INTEGER;
  endnumber INTEGER;
  housenum INTEGER;
  linegeo GEOMETRY;
  splitline GEOMETRY;
  sectiongeo GEOMETRY;
  interpol_postcode TEXT;
  postcode TEXT;
BEGIN
  -- deferred delete
  IF OLD.indexed_status = 100 THEN
    delete from location_property_osmline where place_id = OLD.place_id;
    RETURN NULL;
  END IF;

  IF NEW.indexed_status != 0 OR OLD.indexed_status = 0 THEN
    RETURN NEW;
  END IF;

  NEW.interpolationtype = NEW.address->'interpolation';

  place_centroid := ST_PointOnSurface(NEW.linegeo);
  NEW.parent_place_id = get_interpolation_parent(NEW.osm_id, NEW.address->'street',
                                                 NEW.address->'place',
                                                 NEW.partition, place_centroid, NEW.linegeo);

  IF NEW.address is not NULL AND NEW.address ? 'postcode' AND NEW.address->'postcode' not similar to '%(,|;)%' THEN
    interpol_postcode := NEW.address->'postcode';
    housenum := getorcreate_postcode_id(NEW.address->'postcode');
  ELSE
    interpol_postcode := NULL;
  END IF;

  -- if the line was newly inserted, split the line as necessary
  IF OLD.indexed_status = 1 THEN
      select nodes from planet_osm_ways where id = NEW.osm_id INTO waynodes;

      IF array_upper(waynodes, 1) IS NULL THEN
        RETURN NEW;
      END IF;

      linegeo := NEW.linegeo;
      startnumber := NULL;

      FOR nodeidpos in 1..array_upper(waynodes, 1) LOOP

        select osm_id, address, geometry
          from place where osm_type = 'N' and osm_id = waynodes[nodeidpos]::BIGINT
                           and address is not NULL and address ? 'housenumber' limit 1 INTO nextnode;
        --RAISE NOTICE 'Nextnode.place_id: %s', nextnode.place_id;
        IF nextnode.osm_id IS NOT NULL THEN
          --RAISE NOTICE 'place_id is not null';
          IF nodeidpos > 1 and nodeidpos < array_upper(waynodes, 1) THEN
            -- Make sure that the point is actually on the line. That might
            -- be a bit paranoid but ensures that the algorithm still works
            -- should osm2pgsql attempt to repair geometries.
            splitline := split_line_on_node(linegeo, nextnode.geometry);
            sectiongeo := ST_GeometryN(splitline, 1);
            linegeo := ST_GeometryN(splitline, 2);
          ELSE
            sectiongeo = linegeo;
          END IF;
          endnumber := substring(nextnode.address->'housenumber','[0-9]+')::integer;

          IF startnumber IS NOT NULL AND endnumber IS NOT NULL
             AND startnumber != endnumber
             AND ST_GeometryType(sectiongeo) = 'ST_LineString' THEN

            IF (startnumber > endnumber) THEN
              housenum := endnumber;
              endnumber := startnumber;
              startnumber := housenum;
              sectiongeo := ST_Reverse(sectiongeo);
            END IF;

            -- determine postcode
            postcode := coalesce(interpol_postcode,
                                 prevnode.address->'postcode',
                                 nextnode.address->'postcode',
                                 postcode);

            IF postcode is NULL THEN
                SELECT placex.postcode FROM placex WHERE place_id = NEW.parent_place_id INTO postcode;
            END IF;
            IF postcode is NULL THEN
                postcode := get_nearest_postcode(NEW.country_code, nextnode.geometry);
            END IF;

            IF NEW.startnumber IS NULL THEN
                NEW.startnumber := startnumber;
                NEW.endnumber := endnumber;
                NEW.linegeo := sectiongeo;
                NEW.postcode := upper(trim(postcode));
             ELSE
              insert into location_property_osmline
                     (linegeo, partition, osm_id, parent_place_id,
                      startnumber, endnumber, interpolationtype,
                      address, postcode, country_code,
                      geometry_sector, indexed_status)
              values (sectiongeo, NEW.partition, NEW.osm_id, NEW.parent_place_id,
                      startnumber, endnumber, NEW.interpolationtype,
                      NEW.address, postcode,
                      NEW.country_code, NEW.geometry_sector, 0);
             END IF;
          END IF;

          -- early break if we are out of line string,
          -- might happen when a line string loops back on itself
          IF ST_GeometryType(linegeo) != 'ST_LineString' THEN
              RETURN NEW;
          END IF;

          startnumber := substring(nextnode.address->'housenumber','[0-9]+')::integer;
          prevnode := nextnode;
        END IF;
      END LOOP;
  END IF;

  -- marking descendants for reparenting is not needed, because there are
  -- actually no descendants for interpolation lines
  RETURN NEW;
END;
$$
LANGUAGE plpgsql;
